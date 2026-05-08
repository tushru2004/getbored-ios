import Foundation
import Network
import NetworkExtension
import os.log

final class SafariAppProxyProvider: NEAppProxyProvider {
    private struct ProxySiteRule: Decodable {
        let url: String
    }

    private let logger = Logger(
        subsystem: "com.getbored.ios.safari-app-proxy",
        category: "SafariAppProxyProvider"
    )
    private let contextStore = SafariParentChildContextStore()
    private let parentChildPolicy = SafariParentChildPolicy(activeContextMaxAge: 5)
    private let defaults = UserDefaults(suiteName: SafariParentChildContextStore.appGroupIdentifier)
    private let connectionQueue = DispatchQueue(label: "com.getbored.ios.safari-app-proxy.connections")
    private var relays: [ObjectIdentifier: TCPRelay] = [:]

    override func startProxy(
        options: [String: Any]? = nil,
        completionHandler: @escaping ((any Error)?) -> Void
    ) {
        logger.info("Safari App Proxy spike started")
        appendEvent("START")
        completionHandler(nil)
    }

    override func stopProxy(
        with reason: NEProviderStopReason,
        completionHandler: @escaping () -> Void
    ) {
        logger.info("Safari App Proxy spike stopped reason=\(reason.rawValue, privacy: .public)")
        appendEvent("STOP reason=\(reason.rawValue)")
        completionHandler()
    }

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

    private final class TCPRelay {
        private let flow: NEAppProxyTCPFlow
        private let queue: DispatchQueue
        private let eventSink: (String) -> Void
        private let completion: () -> Void
        private var connection: NWConnection?
        private var didClose = false
        private var flowBytesRead = 0
        private var remoteBytesRead = 0
        private var remoteChunksRead = 0

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

        private func close() {
            guard !didClose else { return }
            didClose = true
            connection?.cancel()
            flow.closeReadWithError(nil)
            flow.closeWriteWithError(nil)
            completion()
        }
    }

    private func describeRemoteEndpoint(for flow: NEAppProxyFlow) -> String {
        if let tcpFlow = flow as? NEAppProxyTCPFlow {
            return String(describing: tcpFlow.remoteEndpoint)
        }
        return String(describing: type(of: flow))
    }

    private func shouldRelayFlow(endpoint: String) -> Bool {
        guard let host = host(from: endpoint) else {
            appendEvent("JOIN_UNSUPPORTED_ENDPOINT endpoint=\(endpoint)")
            return false
        }

        if isDirectlyAllowed(host) {
            appendEvent("APP_PROXY_ALLOW_DIRECT host=\(host) endpoint=\(endpoint)")
            return true
        }

        let decision = parentChildPolicy.decide(
            requestHost: host,
            endpoint: endpoint,
            activeContext: activePageContext()
        )
        if case .matchActiveChild(_, let parent, _) = decision {
            contextStore.saveFlowObservation(
                requestHost: host,
                parentDomain: parent,
                decision: decision.observationDecision,
                endpoint: endpoint,
                observedAt: Date()
            )
        }
        appendEvent(decision.event)

        switch decision {
        case .matchActiveParent:
            appendEvent("APP_PROXY_ALLOW_ACTIVE_PARENT host=\(host) endpoint=\(endpoint)")
            return true
        case .matchActiveChild(_, let parent, _):
            appendEvent("APP_PROXY_ALLOW_ACTIVE_CHILD host=\(host) parent=\(parent) endpoint=\(endpoint)")
            return true
        case .noActiveContext, .staleActiveContext, .noActiveMatch:
            appendEvent("APP_PROXY_BLOCK_PARENT_CHILD host=\(host) decision=\(decision.observationDecision) endpoint=\(endpoint)")
            return false
        }
    }

    private func activePageContext() -> SafariParentChildPolicy.ActivePageContext? {
        guard let active = contextStore.loadActiveContext() else {
            return nil
        }

        return SafariParentChildPolicy.ActivePageContext(
            parent: active.parentDomain,
            children: contextStore.mergedChildren(for: active.parentDomain),
            receivedAt: active.receivedAt
        )
    }

    private func host(from endpoint: String) -> String? {
        let hostPort = endpoint.split(separator: " ", maxSplits: 1).first.map(String.init) ?? endpoint
        guard hostPort.contains(":") else { return nil }
        let host = hostPort.split(separator: ":", maxSplits: 1).first.map(String.init)
        return normalizedHost(host)
    }

    private func normalizedHost(_ value: String?) -> String? {
        value?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .trimmingCharacters(in: CharacterSet(charactersIn: "."))
    }

    private func isDirectlyAllowed(_ host: String) -> Bool {
        if isSystemAllowed(host) {
            return true
        }

        let mode = defaults?.string(forKey: "filter_mode") ?? "blockSpecific"
        let listed = isListed(host)

        if mode == "whiteList" {
            return listed
        }

        return !listed
    }

    private func isListed(_ host: String) -> Bool {
        guard let data = defaults?.data(forKey: "site_rules"),
              let rules = try? JSONDecoder().decode([ProxySiteRule].self, from: data) else {
            return false
        }

        return rules.contains { rule in
            guard let domain = normalizedRuleHost(rule.url), !domain.isEmpty else {
                return false
            }
            return host == domain || host.hasSuffix("." + domain)
        }
    }

    private func normalizedRuleHost(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if let url = URL(string: trimmed), let host = url.host {
            return normalizedHost(host)
        }
        if let url = URL(string: "https://\(trimmed)"), let host = url.host {
            return normalizedHost(host)
        }
        return normalizedHost(trimmed.components(separatedBy: "/").first)
    }

    private func isSystemAllowed(_ host: String) -> Bool {
        [
            "apple.com",
            "amazontrust.com",
            "icloud.com",
            "cdn-apple.com",
            "entrust.net",
            "digicert.com"
        ].contains { suffix in
            host == suffix || host.hasSuffix("." + suffix)
        }
    }

    private func appendEvent(_ event: String) {
        contextStore.appendEvent(event)
    }
}
