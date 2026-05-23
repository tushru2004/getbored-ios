import Foundation
import GetBoredCore
import Network
import NetworkExtension
import os.log

/// `NEAppProxyProvider` subclass that runs as the Safari per-app VPN extension.
///
/// **Role in the parent-child architecture:**
/// This is layer 1 of 3 in the Safari filter defense — it intercepts every
/// outbound TCP flow from Safari and asks Kotlin for the relay decision using
/// the rule snapshot plus the active Safari parent-child context.
///
/// **Lifecycle:**
/// - iOS calls `startProxy(...)` once when the per-app VPN comes up.
/// - iOS calls `handleNewFlow(_:)` once per outbound TCP/UDP connection.
/// - iOS calls `stopProxy(...)` when the user disables the profile or it errors.
///
/// **Bundle ID:** `com.getbored.advance.whitelist.SafariAppProxyProvider`
/// **Per-app VPN scope:** Safari only (Mobile Safari bundle ID).
/// **Profile:** `com.getbored.ios.safari-app-proxy-spike` (mobileconfig).
final class SafariAppProxyProvider: NEAppProxyProvider {
    /// Unified-logging handle. Subsystem visible in Console.app under
    /// `com.getbored.ios.safari-app-proxy`. Use `log show --predicate
    /// 'subsystem == "com.getbored.ios.safari-app-proxy"' --last 5m`.
    private let logger = Logger(
        subsystem: GetBoredIdentifiers.Logging.iosSafariAppProxy,
        category: "SafariAppProxyProvider"
    )

    /// Reads/writes the App Group keys that hold the active Safari page context
    /// + child registrations + spike event log. Owned by:
    /// - `SafariChildRegistrationExtension` (writer)
    /// - this provider (reader)
    /// - host app `ContentView` (reader for the spike inspector UI).
    private let contextStore = SafariParentChildContextStore()
    private let ruleStore = IOSRuleStore.shared

    /// Contexts older than 60s are treated as stale to prevent background tabs
    /// from reusing old whitelists while still allowing delayed CNBC resources.
    private let activeContextMaxAge: TimeInterval = 60
    private let activeContextRefreshMinAge: TimeInterval = 3

    /// Apple/system infrastructure domains that must always be allowed. Loaded
    /// from GetBoredCore's bundled list with a legacy Safari App Proxy fallback
    /// suffix preserved for compatibility.
    private let systemAllowedSuffixes: [String] = {
        var suffixes = SystemAllowList.load(from: Bundle(for: SafariAppProxyProvider.self))
        if !suffixes.contains("amazontrust.com") {
            suffixes.append("amazontrust.com")
        }
        return suffixes
    }()

    /// App Group `UserDefaults` shared with the host app, the iOS content
    /// filter, and the Safari registration extension.
    /// Suite: `group.com.getbored.advance.whitelist`.
    private let defaults = UserDefaults(suiteName: SafariParentChildContextStore.appGroupIdentifier)

    /// Serial queue that owns all `NWConnection` + `relays` dict mutations.
    /// Single queue → no locks required, FIFO ordering of state transitions.
    private let connectionQueue = DispatchQueue(label: GetBoredIdentifiers.Queue.iosSafariConnections)

    /// Strong references to in-flight relays, keyed by `ObjectIdentifier(flow)`.
    /// Without this dict, ARC would free a relay the moment `handleNewFlow`
    /// returns and the underlying `NWConnection` would die mid-handshake.
    /// Mutated only on `connectionQueue`.
    private var relays: [ObjectIdentifier: TCPRelay] = [:]

    /// Called by iOS when the per-app VPN profile becomes active.
    ///
    /// Example: user toggles "Safari App Proxy Spike" on in Settings →
    /// Network → VPN → iOS instantiates this provider → calls `startProxy`.
    ///
    /// We just log + ack. No tunnel handshake needed because per-app proxy
    /// works at the flow layer, not the IP layer.
    override func startProxy(
        options: [String: Any]? = nil,
        completionHandler: @escaping ((any Error)?) -> Void
    ) {
        logger.info("Safari App Proxy spike started")
        appendEvent("START")
        completionHandler(nil)
    }

    /// Called by iOS when the per-app VPN is being torn down.
    ///
    /// Reasons (`NEProviderStopReason`): `.userInitiated`, `.providerFailed`,
    /// `.connectionFailed`, `.userLogout`, `.appUpdate`, etc.
    /// We log the reason for spike telemetry, then ack.
    override func stopProxy(
        with reason: NEProviderStopReason,
        completionHandler: @escaping () -> Void
    ) {
        logger.info("Safari App Proxy spike stopped reason=\(reason.rawValue, privacy: .public)")
        appendEvent("STOP reason=\(reason.rawValue)")
        completionHandler()
    }

    /// Called by iOS once for every new TCP/UDP connection Safari opens while
    /// the App Proxy is the active per-app VPN.
    ///
    /// Example: user navigates to `https://cnbc.com` — Safari opens flows for
    /// `cnbc.com:443`, `sb.scorecardresearch.com:443`,
    /// `secure-us.imrworldwide.com:443`. Each one calls `handleNewFlow()` once
    /// with a separate `flow` object.
    ///
    /// Returning `true`  = "I will proxy this flow myself" → relay starts.
    /// Returning `false` = "I won't handle this" → iOS drops the connection
    /// (per-app VPN scope means there is no system fallback path).
    ///
    /// Step-by-step:
    /// 1. **Policy gate** (`shouldRelayFlow`) — runs the KMP direct Safari
    ///    proxy decision (site_rules / system allowlist) + KMP parent-child
    ///    decision (active Safari page context match).
    ///    - `cnbc.com` is the active parent → `Decision.matchActiveParent` → allow.
    ///    - `sb.scorecardresearch.com` is a registered child of `cnbc.com`
    ///      within the 5s active window → `Decision.matchActiveChild` → allow.
    ///    - `random-tracker.example.com` with no parent context → block.
    /// 2. **TCP-only filter** — `NEAppProxyFlow` is abstract; concrete subclasses
    ///    are `NEAppProxyTCPFlow` and `NEAppProxyUDPFlow`. This spike only
    ///    relays TCP (HTTPS = TCP/443). UDP / QUIC → drop.
    /// 3. **Build relay** — `TCPRelay` bridges the Safari-side flow ↔ a real
    ///    outbound `NWConnection`.
    ///    - `eventSink` writes to the App Group event log.
    ///    - `completion` runs when the relay tears down — removes self from
    ///      `relays` so ARC can free.
    ///    - `[weak self]` avoids a retain cycle:
    ///      `self → relays → relay → completion → self`.
    /// 4. **Store before start** — relay is inserted into `relays[id]` BEFORE
    ///    `start()`. Without this, the local var goes out of scope at function
    ///    return, ARC frees the relay, and `NWConnection` dies before any byte
    ///    is read. `connectionQueue` is a serial queue so dict mutation is
    ///    thread-safe.
    ///
    /// `ObjectIdentifier(tcpFlow)` is used as the dict key — pointer-identity,
    /// stable Hashable, unique per flow object.
    override func handleNewFlow(_ flow: NEAppProxyFlow) -> Bool {
        let endpoint = describeRemoteEndpoint(for: flow)
        let source = flow.metaData.sourceAppSigningIdentifier
        logger.info("Safari App Proxy flow source=\(source, privacy: .public) endpoint=\(endpoint, privacy: .public)")
        appendEvent("FLOW source=\(source) endpoint=\(endpoint)")

        guard shouldRelayFlow(endpoint: endpoint) else {
            logger.info("Safari App Proxy blocked endpoint=\(endpoint, privacy: .public)")
            return false
        }

        guard let tcpFlow = flow as? NEAppProxyTCPFlow else {
            appendEvent("UNSUPPORTED source=\(source) endpoint=\(endpoint)")
            return false
        }

        let id = ObjectIdentifier(tcpFlow)
        let relay = TCPRelay(
            flow: tcpFlow,
            queue: connectionQueue,
            eventSink: { [weak self] event in self?.appendEvent(event) },
            completion: { [weak self] in
                self?.connectionQueue.async {
                    self?.relays[id] = nil
                }
            }
        )

        connectionQueue.async {
            self.relays[id] = relay
            relay.start()
        }
        return true
    }

    /// Per-flow byte pump. Owns one Safari-side `NEAppProxyTCPFlow` and one
    /// outbound real `NWConnection`, copying bytes between them in both
    /// directions until either side closes.
    ///
    /// Pipeline once `start()` is called:
    /// ```
    /// start()
    ///   └─ NWConnection.start                 ← open real socket
    ///        └─ stateUpdateHandler(.ready)
    ///             └─ openFlow                 ← tell Safari "go ahead, write"
    ///                  ├─ readFromFlow()      ← pump Safari → server
    ///                  └─ readFromConnection()← pump server → Safari
    /// ```
    ///
    /// `didClose` makes `close()` idempotent — both sides may EOF independently
    /// and we only want one teardown.
    private final class TCPRelay {
        /// Safari-side flow. Provides `readData`, `write`, `closeRead/Write`.
        private let flow: NEAppProxyTCPFlow
        /// Serial queue inherited from the provider. All callbacks fire here.
        private let queue: DispatchQueue
        /// Hop for log lines into the App Group event log (host app reads it).
        private let eventSink: (String) -> Void
        /// Called once when this relay is fully torn down — provider uses it to
        /// remove its strong reference from `relays[id]`.
        private let completion: () -> Void
        /// Real outbound TCP socket (Network.framework). nil before `start()`.
        private var connection: NWConnection?
        /// Tripwire so `close()` runs exactly once even if both pumps fail.
        private var didClose = false
        /// Cumulative byte counters used to log "first chunk" markers — useful
        /// in the spike inspector for confirming bidirectional traffic.
        private var flowBytesRead = 0
        private var remoteBytesRead = 0
        private var remoteChunksRead = 0

        /// Stores the four collaborators. Doesn't kick anything off — caller
        /// must invoke `start()` after stashing the relay in the parent dict.
        init(
            flow: NEAppProxyTCPFlow,
            queue: DispatchQueue,
            eventSink: @escaping (String) -> Void,
            completion: @escaping () -> Void
        ) {
            self.flow = flow
            self.queue = queue
            self.eventSink = eventSink
            self.completion = completion
        }

        /// Step 1 of the pipeline: open the real outbound socket.
        ///
        /// `makeEndpoint()` extracts host+port from the Safari flow. If the
        /// endpoint shape is unrecognized (e.g. Bonjour) we abort.
        ///
        /// `NWConnection(to:using: .tcp)` does not connect synchronously —
        /// it transitions through `.preparing` → `.ready` (or `.failed`). The
        /// `stateUpdateHandler` is where the next step happens.
        func start() {
            guard let endpoint = makeEndpoint() else {
                eventSink("RELAY_UNSUPPORTED_ENDPOINT endpoint=\(flow.remoteEndpoint)")
                close()
                return
            }

            let connection = NWConnection(to: endpoint, using: .tcp)
            self.connection = connection
            connection.stateUpdateHandler = { [weak self] state in
                self?.handleConnectionState(state)
            }
            connection.start(queue: queue)
        }

        /// Routes `NWConnection` state changes.
        ///
        /// - `.ready`     → real socket connected → tell Safari to start writing.
        /// - `.failed`    → DNS / TCP / TLS error → log + tear down.
        /// - `.cancelled` → we cancelled it ourselves in `close()` → finish teardown.
        /// - other states (`.setup`, `.preparing`, `.waiting`) → ignored; we'll
        ///   get a follow-up event.
        private func handleConnectionState(_ state: NWConnection.State) {
            switch state {
            case .ready:
                eventSink("RELAY_READY endpoint=\(flow.remoteEndpoint)")
                openFlow()
            case .failed(let error):
                eventSink("RELAY_FAILED endpoint=\(flow.remoteEndpoint) error=\(error)")
                close()
            case .cancelled:
                close()
            default:
                break
            }
        }

        /// Step 2: open the Safari-side flow.
        ///
        /// `NEAppProxyTCPFlow` requires `open(...)` before `readData/write`
        /// will work. Without this, Safari's send queue stays buffered.
        ///
        /// iOS 18 added `open(withLocalFlowEndpoint:)` (typed). Pre-18 only
        /// has the deprecated `open(withLocalEndpoint:)` taking a String.
        /// Once open completes successfully, the two pumps start in parallel.
        private func openFlow() {
            let completion: (Error?) -> Void = { [weak self] error in
                guard let self else { return }
                if let error {
                    self.eventSink("FLOW_OPEN_FAILED endpoint=\(self.flow.remoteEndpoint) error=\(error)")
                    self.close()
                    return
                }
                self.eventSink("FLOW_OPENED endpoint=\(self.flow.remoteEndpoint)")
                self.readFromFlow()
                self.readFromConnection()
            }

            if #available(iOS 18.0, *) {
                flow.open(withLocalFlowEndpoint: nil, completionHandler: completion)
            } else {
                flow.open(withLocalEndpoint: nil, completionHandler: completion)
            }
        }

        /// Pump A: **Safari → server**.
        ///
        /// `flow.readData` is callback-style and one-shot — must re-arm after
        /// each chunk by calling itself again from inside the send completion.
        ///
        /// EOF handling: empty `data` (with no error) means Safari finished
        /// uploading. We forward EOF to the real socket via `send(content: nil)`
        /// (NWConnection's way of doing TCP half-close).
        ///
        /// Example: TLS ClientHello arrives (~520 bytes) → log
        /// `FLOW_READ_FIRST` → `connection.send` it → re-arm `readFromFlow()`.
        private func readFromFlow() {
            flow.readData { [weak self] data, error in
                guard let self else { return }
                if let error {
                    self.eventSink("FLOW_READ_FAILED endpoint=\(self.flow.remoteEndpoint) error=\(error)")
                    self.close()
                    return
                }
                guard let data, !data.isEmpty else {
                    self.eventSink("FLOW_READ_EOF endpoint=\(self.flow.remoteEndpoint)")
                    self.connection?.send(content: nil, completion: .contentProcessed { _ in })
                    return
                }
                self.flowBytesRead += data.count
                if self.flowBytesRead == data.count {
                    self.eventSink("FLOW_READ_FIRST endpoint=\(self.flow.remoteEndpoint) bytes=\(data.count)")
                }
                self.connection?.send(content: data, completion: .contentProcessed { [weak self] error in
                    guard let self else { return }
                    if let error {
                        self.eventSink("REMOTE_WRITE_FAILED endpoint=\(self.flow.remoteEndpoint) error=\(error)")
                        self.close()
                        return
                    }
                    self.readFromFlow()
                })
            }
        }

        /// Pump B: **server → Safari**.
        ///
        /// `connection.receive` is also one-shot — re-arm by calling itself.
        /// `maximumLength: 64KB` is a reasonable HTTPS chunk size; small enough
        /// to keep memory bounded, large enough that we don't spam syscalls.
        ///
        /// `isComplete` is the server-side EOF signal. When seen we mirror it
        /// to Safari with `closeWriteWithError(nil)` and tear down the relay
        /// (response is fully delivered).
        ///
        /// Example: TLS ServerHello + cert chain (~4KB) arrives → log
        /// `REMOTE_READ_FIRST` + `FLOW_WRITE_START` → `flow.write` → on success,
        /// re-arm `readFromConnection()` for the next ApplicationData record.
        private func readFromConnection() {
            connection?.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
                guard let self else { return }
                if let error {
                    self.eventSink("REMOTE_READ_FAILED endpoint=\(self.flow.remoteEndpoint) error=\(error)")
                    self.close()
                    return
                }
                if let data, !data.isEmpty {
                    self.remoteBytesRead += data.count
                    self.remoteChunksRead += 1
                    if self.remoteBytesRead == data.count {
                        self.eventSink("REMOTE_READ_FIRST endpoint=\(self.flow.remoteEndpoint) bytes=\(data.count)")
                    }
                    self.eventSink("FLOW_WRITE_START endpoint=\(self.flow.remoteEndpoint) chunk=\(self.remoteChunksRead) bytes=\(data.count)")
                    self.flow.write(data) { [weak self] error in
                        guard let self else { return }
                        if let error {
                            self.eventSink("FLOW_WRITE_FAILED endpoint=\(self.flow.remoteEndpoint) error=\(error)")
                            self.close()
                            return
                        }
                        self.eventSink("FLOW_WRITE_DONE endpoint=\(self.flow.remoteEndpoint) chunk=\(self.remoteChunksRead) bytes=\(data.count)")
                        if isComplete {
                            self.flow.closeWriteWithError(nil)
                            self.close()
                        } else {
                            self.readFromConnection()
                        }
                    }
                } else if isComplete {
                    self.flow.closeWriteWithError(nil)
                    self.close()
                } else {
                    self.readFromConnection()
                }
            }
        }

        /// Convert the Safari-side `remoteEndpoint` into a Network.framework
        /// `NWEndpoint` we can dial.
        ///
        /// Two paths:
        /// 1. iOS 18+ exposes a typed `remoteFlowEndpoint` enum — preferred.
        /// 2. Legacy: parse the deprecated stringly-typed `remoteEndpoint`
        ///    description, e.g. `cnbc.com:443` → `("cnbc.com", 443)`.
        ///
        /// Returns nil for unsupported shapes (no port, IPv6 with embedded
        /// colons that the simple split mishandles, Bonjour names, etc.) —
        /// caller treats nil as drop.
        private func makeEndpoint() -> Network.NWEndpoint? {
            if #available(iOS 18.0, *) {
                switch flow.remoteFlowEndpoint {
                case .hostPort(let host, let port):
                    return .hostPort(host: host, port: port)
                default:
                    break
                }
            }

            let description = String(describing: flow.remoteEndpoint)
            let parts = description.split(separator: ":", maxSplits: 1).map(String.init)
            guard parts.count == 2, let port = UInt16(parts[1]), let nwPort = NWEndpoint.Port(rawValue: port) else {
                return nil
            }
            return .hostPort(host: NWEndpoint.Host(parts[0]), port: nwPort)
        }

        /// Idempotent teardown. Safe to call from any code path — first call
        /// runs the cleanup, subsequent calls no-op via `didClose`.
        ///
        /// Order matters:
        /// 1. Cancel the real socket (won't fire `.cancelled` if already cancelled).
        /// 2. Half-close both directions on the Safari flow.
        /// 3. Notify the parent provider via `completion()` so it drops its
        ///    strong ref → ARC frees this relay.
        private func close() {
            guard !didClose else { return }
            didClose = true
            connection?.cancel()
            flow.closeReadWithError(nil)
            flow.closeWriteWithError(nil)
            completion()
        }
    }

    /// Stringify a flow's remote endpoint for logging.
    /// Returns the type name for non-TCP flows so the log shows e.g.
    /// `NEAppProxyUDPFlow` instead of an empty string.
    private func describeRemoteEndpoint(for flow: NEAppProxyFlow) -> String {
        if let tcpFlow = flow as? NEAppProxyTCPFlow {
            return String(describing: tcpFlow.remoteEndpoint)
        }
        return String(describing: type(of: flow))
    }

    /// Top-level allow/block decision for an outbound flow.
    ///
    /// Swift owns the side effects around the Kotlin decision: reading stored
    /// context, refreshing context timestamps, saving flow observations, and
    /// appending structured events for the host app's spike inspector.
    private func shouldRelayFlow(endpoint: String) -> Bool {
        let active = contextStore.loadActiveContext()
        let activeChildren = active.map { Array(contextStore.mergedChildren(for: $0.parentDomain)).sorted() } ?? []
        let decision = KMPDecisionCoreAdapter.safariRelayDecision(
            endpoint: endpoint,
            using: loadedFilterRules(),
            systemAllowedSuffixes: systemAllowedSuffixes,
            activeParent: active?.parentDomain,
            activeChildren: activeChildren,
            activeContextAge: active.map { Date().timeIntervalSince($0.receivedAt) } ?? 0,
            activeContextMaxAge: activeContextMaxAge,
            activeContextRefreshMinAge: activeContextRefreshMinAge
        )

        if decision.shouldRefreshActiveContext, let active {
            contextStore.saveActiveContext(
                parentDomain: active.parentDomain,
                childDomains: activeChildren,
                url: active.url,
                receivedAt: Date()
            )
            appendEvent(decision.refreshEvent)
        }

        appendEvent(decision.primaryEvent)

        if decision.shouldSaveFlowObservation {
            contextStore.saveFlowObservation(
                requestHost: decision.host,
                parentDomain: decision.activeParent,
                decision: decision.observationDecision,
                endpoint: endpoint,
                observedAt: Date()
            )
        }

        if !decision.outcomeEvent.isEmpty {
            appendEvent(decision.outcomeEvent)
        }

        return decision.shouldRelay
    }

    /// Load the Swift-owned policy snapshot from App Group storage, then pass
    /// it across the KMP adapter boundary for pure decision logic.
    private func loadedFilterRules() -> LoadedFilterRules {
        ruleStore.loadFilterRules()
    }

    /// Append a single line to the App Group spike event log.
    /// The host app's spike inspector tail-reads this for live decision history.
    private func appendEvent(_ event: String) {
        contextStore.appendEvent(event)
    }
}
