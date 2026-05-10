//
//  FilterDataProvider.swift
//  iOSFilterDataProvider
//
//  Created by Tushar on 25.02.26.
//

import Foundation
import NetworkExtension
import os.log

class FilterDataProvider: NEFilterDataProvider {

    private let logger = OSLog(subsystem: GetBoredIdentifiers.Logging.iOS, category: "FilterDataProvider")
    private let safariParentChildContextStore = SafariParentChildContextStore()
    private let safariParentChildObservationMaxAge: TimeInterval = 10

    /// Current filter mode, refreshed on every classification call
    private var currentMode: String = "blockSpecific"

    /// Throttle app-level block probes: one per app per 30 seconds
    private var lastAppProbeLogAt: [String: Date] = [:]
    private let appProbeCooldown: TimeInterval = 30

    // MARK: - Always-Allowed System Domains

    /// Apple infrastructure domains that must always be allowed.
    /// Blocking these breaks iCloud, App Store, certificate validation, etc.
    /// Reference: https://support.apple.com/en-us/101555
    private let systemAllowedSuffixes: [String] = {
        // Load from bundled system-allowed.json
        let url = Bundle.main.url(forResource: "system-allowed", withExtension: "json")
        if let url = url {
            let data = try? Data(contentsOf: url)
            if let data = data {
                let decoded = try? JSONDecoder().decode([String: [String: [String]]].self, from: data)
                if let groups = decoded?["systemAllowedSuffixes"] {
                    return groups.values.flatMap { $0 }
                }
            }
        }
        // Fallback: Apple core services + certs (bare minimum to not break the system)
        return ["apple.com", "icloud.com", "cdn-apple.com", "entrust.net", "digicert.com"]
    }()

    /// Check if a host is an Apple system domain that should never be blocked
    private func isSystemAllowed(_ host: String) -> Bool {
        let h = host.trimmingCharacters(in: CharacterSet(charactersIn: ".")).lowercased()
        return systemAllowedSuffixes.contains(where: { suffix in
            h == suffix || h.hasSuffix("." + suffix)
        })
    }

    // MARK: - Lifecycle

    /// Called by iOS when the content filter is activated.
    override func startFilter(completionHandler: @escaping (Error?) -> Void) {
        os_log("Filter starting – TLS SNI + HTTP Host inspection mode", log: logger, type: .info)
        currentMode = IOSRuleStore.shared.getMode()
        os_log("Filter initial mode: %{public}@", log: logger, type: .info, currentMode)
        completionHandler(nil)
    }

    /// Called by iOS when the content filter is deactivated.
    override func stopFilter(with reason: NEProviderStopReason, completionHandler: @escaping () -> Void) {
        os_log("Filter stopped: %{public}@", log: logger, type: .info, String(describing: reason))
        completionHandler()
    }

    // MARK: - Telemetry Helpers

    /// Log a blocked app event. Fallback telemetry when the normal
    /// CP logging path (via .needRules()) doesn't reliably surface the app.
    private func logBlockedAppTelemetry(sourceApp: String?, domain: String, reason: String, resolutionSource: String) {
        guard let sourceApp, !sourceApp.isEmpty else { return }
        os_log("logBlockedAppTelemetry: sourceApp=%{public}@ domain=%{public}@",
               log: logger, type: .info, sourceApp, domain)
        IOSActivityLogger.shared.log(
            domain: domain,
            blocked: true,
            reason: reason,
            sourceApp: sourceApp,
            rawEndpoint: nil,
            resolutionSource: resolutionSource,
            isResolvableHostname: !domain.lowercased().hasPrefix("app:")
        )
    }

    // MARK: - Host Classification

    /// The decision engine. Returns (shouldBlock, reason) for a given hostname.
    /// Called every time we extract a hostname from a network flow.
    ///
    /// The same site rules list means different things depending on mode:
    /// - blockSpecific: the list is a BLOCKLIST (block what's listed)
    /// - whiteList: the list is an ALLOWLIST (allow what's listed, block everything else)
    private func classifyHost(_ host: String) -> (blocked: Bool, reason: String) {
        // Always re-read the mode — it could change at any time via CloudKit sync
        currentMode = IOSRuleStore.shared.getMode()

        // Block-everything mode: only sites in the list (and their CDNs) are allowed
        if currentMode == "whiteList" {
            if IOSRuleStore.shared.isListed(url: host) {
                return (false, "In allowed list")
            }
            if let parent = allowedSafariParent(forChildHost: host) {
                return (false, "Child of allowed Safari parent \(parent)")
            }
            return (true, "Block everything mode")
        }

        // Default blocklist mode: block if no entries exist (lockdown) or if listed
        if !IOSRuleStore.shared.hasAnyEntries() {
            return (true, "No entries (lockdown)")
        }
        if IOSRuleStore.shared.isListed(url: host) {
            return (true, "In blocklist")
        }
        return (false, "Not listed")
    }

    private func allowedSafariParent(forChildHost host: String) -> String? {
        guard let match = safariParentChildContextStore.freshChildAllowMatch(
            for: host,
            maxAge: safariParentChildObservationMaxAge
        ) else {
            return nil
        }

        guard IOSRuleStore.shared.isListed(url: match.parentDomain) else {
            os_log("allowedSafariParent: rejecting child=%{public}@ parent=%{public}@ because parent is not in allowlist",
                   log: logger, type: .info, host, match.parentDomain)
            safariParentChildContextStore.appendEvent(
                String(
                    format: "DATA_PROVIDER_REJECT_CHILD_PARENT_NOT_ALLOWLISTED host=%@ parent=%@ age=%.1f",
                    host,
                    match.parentDomain,
                    match.age
                )
            )
            return nil
        }

        os_log("allowedSafariParent: allowing child=%{public}@ parent=%{public}@ age=%.1f",
               log: logger, type: .info, host, match.parentDomain, match.age)
        safariParentChildContextStore.appendEvent(
            String(
                format: "DATA_PROVIDER_ALLOW_CHILD host=%@ parent=%@ age=%.1f",
                host,
                match.parentDomain,
                match.age
            )
        )
        return match.parentDomain
    }

    // MARK: - Telemetry Helpers

    /// Emit at most one "app probe" per app per cooldown window.
    /// In block-everything mode, a blocked app sends dozens of requests.
    /// This limits to one log entry per app every 30 seconds.
    private func logBlockedAppProbeIfNeeded(sourceApp: String?) {
        guard let sourceApp, !sourceApp.isEmpty else { return }
        let appKey = sourceApp.lowercased()
        let now = Date()
        if let last = lastAppProbeLogAt[appKey], now.timeIntervalSince(last) < appProbeCooldown {
            return
        }
        lastAppProbeLogAt[appKey] = now
        logBlockedAppTelemetry(
            sourceApp: sourceApp,
            domain: "app:\(sourceApp)",
            reason: "Blocked by filter (app probe)",
            resolutionSource: "data-provider-app-probe"
        )
    }

    #if DEBUG
    /// Spike-only probe for deciding whether parent-child enforcement can live
    /// in the existing content filter instead of the Safari App Proxy.
    private func logParentChildOwnerProbe(flow: NEFilterFlow, host: String, url: URL) {
        let sourceApp = flow.sourceAppIdentifier ?? "nil"
        if let browserFlow = flow as? NEFilterBrowserFlow {
            let parentURL = browserFlow.parentURL?.absoluteString ?? "nil"
            let requestURL = browserFlow.request?.url?.absoluteString ?? "nil"
            os_log("PARENT_CHILD_OWNER_PROBE layer=DataProvider type=NEFilterBrowserFlow host=%{public}@ url=%{public}@ requestURL=%{public}@ parentURL=%{public}@ sourceApp=%{public}@",
                   log: logger,
                   type: .info,
                   host,
                   url.absoluteString,
                   requestURL,
                   parentURL,
                   sourceApp)
        } else {
            os_log("PARENT_CHILD_OWNER_PROBE layer=DataProvider type=%{public}@ host=%{public}@ url=%{public}@ parentURL=unavailable sourceApp=%{public}@",
                   log: logger,
                   type: .info,
                   String(describing: type(of: flow)),
                   host,
                   url.absoluteString,
                   sourceApp)
        }
    }
    #endif

    // MARK: - Flow Handling (Chunk 4)

    /// This is the busiest method in the whole filter. Every single network request
    /// on the phone goes through it. Here's the decision tree:
    ///
    /// iOS detects new network connection → handleNewFlow(flow)
    ///     │
    ///     ├─ 1. Is it an Apple system app (not Safari)?
    ///     │     YES → .allow()  (Apple apps use weird CDN domains, let them through)
    ///     │
    ///     ├─ 2. Is the app in the user's allowed-apps list?
    ///     │     YES → .allow()  (parent explicitly whitelisted this app)
    ///     │
    ///     ├─ 3. App not allowed + whiteList mode?
    ///     │     YES → log one "app probe" per 30 seconds (for the Block Log)
    ///     │
    ///     ├─ 4. Is this QUIC? (UDP port 443, used by HTTP/3)
    ///     │     YES → classifyHost(endpoint.hostname)
    ///     │           blocked? → .needRules() (escalate to Control Provider)
    ///     │
    ///     ├─ 5. Does the flow have a URL? (browser like Safari)
    ///     │     YES → classifyHost(host)
    ///     │           blocked? → check exceptions first, then .needRules()
    ///     │
    ///     └─ 6. No URL? (non-browser app like TikTok, Instagram app)
    ///           → "Give me the first 512 outbound bytes to inspect"
    ///           → iOS will call handleOutboundData() next
    ///
    /// This method handles browsers (step 5) and QUIC (step 4) completely.
    /// But non-browser apps like TikTok, Instagram, YouTube, Snapchat give us
    /// NO URL — flow.url is nil. Without chunk 5 (handleOutboundData), every
    /// non-browser app would slip through unfiltered. That's most of the traffic
    /// on a teenager's phone.
    override func handleNewFlow(_ flow: NEFilterFlow) -> NEFilterNewFlowVerdict {
        let sourceApp = flow.sourceAppIdentifier

        // ── Step 1 & 2: Per-app checks ──────────────────────────────────
        if let sourceApp {
            os_log("handleNewFlow: checking sourceApp=%{public}@", log: logger, type: .info, sourceApp)

            // 1a. Always allow our own app — it needs CloudKit for sync/registration
            let appLower = sourceApp.lowercased()
            if appLower.contains("com.getbored.") {
                return .allow()
            }

            // 1b. Always allow Apple system apps (com.apple.*) — they use CDN domains
            //     that would clutter the Block Log. Safari excluded: it's a browser.
            if (appLower.hasSuffix(".com.apple.") || appLower.contains(".com.apple."))
                && !appLower.contains("mobilesafari") {
                return .allow()
            }

            // 2. Check the user's allowed-apps list
            if IOSRuleStore.shared.isAppAllowed(sourceApp) {
                os_log("handleNewFlow: allowing whitelisted app: %{public}@",
                       log: logger, type: .info, sourceApp)
                return .allow()
            }

            // 3. App not allowed + whiteList → emit one app probe per cooldown window
            let mode = IOSRuleStore.shared.getMode()
            if mode == "whiteList" {
                logBlockedAppProbeIfNeeded(sourceApp: sourceApp)
            }
        }

        // ── Step 4: QUIC (HTTP/3) ───────────────────────────────────────
        // QUIC uses UDP port 443. Our TLS SNI parser only handles TCP,
        // but iOS can still provide the hostname on the socket flow. Prefer
        // remoteHostname because the endpoint hostname can be only an IP.
        if let socketFlow = flow as? NEFilterSocketFlow,
           let endpoint = socketFlow.remoteEndpoint as? NWHostEndpoint,
           endpoint.port == "443",
           socketFlow.socketType == Int32(SOCK_DGRAM) {
            let host = socketFlow.remoteHostname ?? endpoint.hostname
            if isSystemAllowed(host) {
                return .allow()
            }
            let result = classifyHost(host)
            if result.blocked {
                os_log("handleNewFlow: QUIC BLOCKED %{public}@ endpoint=%{public}@ → routing to CP",
                       log: logger, type: .info, host, endpoint.hostname)
                return .needRules()
            }
            return .allow()
        }

        // ── Step 5: Browser flows (have a URL) ──────────────────────────
        if let url = flow.url, let host = url.host?.lowercased() {
            #if DEBUG
            logParentChildOwnerProbe(flow: flow, host: host, url: url)
            #endif
            if isSystemAllowed(host) {
                return .allow()
            }
            let result = classifyHost(host)
            if result.blocked {
                // Check URL path exceptions (e.g. "instagram.com/school-account")
                if IOSRuleStore.shared.isExcepted(fullURL: url.absoluteString) {
                    os_log("handleNewFlow: exception match for %{public}@",
                           log: logger, type: .info, url.absoluteString)
                    return .allow()
                }
                os_log("handleNewFlow: BLOCKED %{public}@ (%{public}@) → routing to CP",
                       log: logger, type: .info, host, result.reason)
                return .needRules()
            }
            return .allow()
        }

        // ── Step 6: No URL (non-browser app) ────────────────────────────
        // Ask iOS for the first 512 outbound bytes so we can parse
        // TLS ClientHello (SNI) or HTTP Host header in handleOutboundData()
        return NEFilterNewFlowVerdict.filterDataVerdict(
            withFilterInbound: false,
            peekInboundBytes: 0,
            filterOutbound: true,
            peekOutboundBytes: 512
        )
    }

    // MARK: - Outbound Data Inspection (Chunk 5)

    /// This is the callback for step 6 above. When handleNewFlow() couldn't find
    /// a hostname (non-browser apps like TikTok, Instagram, YouTube, Snapchat),
    /// it asked iOS for the first 512 outbound bytes. iOS delivers them here.
    ///
    /// We dig through the raw bytes to find the hostname:
    ///
    /// iOS delivers 512 raw bytes → handleOutboundData()
    ///     │
    ///     ├─ Try 1: Is this a TLS ClientHello? (HTTPS — most apps)
    ///     │   extractSNI() parses the binary TLS record
    ///     │   Found hostname → classifyHost() → blocked? → .drop()
    ///     │
    ///     ├─ Try 2: Is this an HTTP request? (plain HTTP — rare)
    ///     │   extractHTTPHost() reads the "Host:" header
    ///     │   Found hostname → classifyHost() → check exceptions → .drop()
    ///     │
    ///     └─ Neither? (DNS, mDNS, system traffic)
    ///           → .allow()
    ///
    /// KEY DIFFERENCE from handleNewFlow: we use .drop() here, not .needRules().
    /// By the time we're inspecting raw bytes, .needRules() doesn't reliably
    /// trigger the Control Provider. So we drop directly and log via telemetry.
    override func handleOutboundData(from flow: NEFilterFlow,
                                     readBytesStartOffset offset: Int,
                                     readBytes: Data) -> NEFilterDataVerdict {
        // ── Try 1: TLS ClientHello → extract SNI hostname ───────────────
        if let sni = extractSNI(from: readBytes) {
            if isSystemAllowed(sni) { return .allow() }
            let result = classifyHost(sni)
            if result.blocked {
                os_log("handleOutboundData: BLOCKED SNI %{public}@ (%{public}@)",
                       log: logger, type: .info, sni, result.reason)
                logBlockedAppTelemetry(
                    sourceApp: flow.sourceAppIdentifier,
                    domain: sni,
                    reason: result.reason,
                    resolutionSource: "data-provider-sni"
                )
                return .drop()
            }
            return .allow()
        }

        // ── Try 2: HTTP request → extract Host header ───────────────────
        if let host = extractHTTPHost(from: readBytes) {
            if isSystemAllowed(host) { return .allow() }
            let result = classifyHost(host)
            if result.blocked {
                // Check URL path exceptions for HTTP
                if let fullURL = extractHTTPFullURL(from: readBytes),
                   IOSRuleStore.shared.isExcepted(fullURL: fullURL) {
                    return .allow()
                }
                os_log("handleOutboundData: BLOCKED HTTP %{public}@ (%{public}@)",
                       log: logger, type: .info, host, result.reason)
                logBlockedAppTelemetry(
                    sourceApp: flow.sourceAppIdentifier,
                    domain: host,
                    reason: result.reason,
                    resolutionSource: "data-provider-http"
                )
                return .drop()
            }
            return .allow()
        }

        // ── Neither TLS nor HTTP — allow (DNS, mDNS, system traffic) ────
        return .allow()
    }

    // MARK: - TLS SNI Extraction

    /// Parse a TLS ClientHello record to extract the Server Name Indication (SNI).
    ///
    /// When an app opens an HTTPS connection, the very first message it sends is a
    /// "ClientHello" — an unencrypted handshake that includes the hostname the client
    /// wants to connect to. This is how we identify which domain a non-browser app
    /// is talking to (e.g. TikTok connecting to "tiktok.com").
    ///
    /// TLS record layout (we walk through this byte by byte):
    /// ```
    /// [0]     ContentType     = 0x16 (Handshake)
    /// [1-2]   TLS Version
    /// [3-4]   Record Length
    /// [5]     HandshakeType   = 0x01 (ClientHello)
    /// [6-8]   Handshake Length
    /// [9-10]  Client Version
    /// [11-42] Random (32 bytes)
    /// [43]    Session ID Length → skip session ID
    ///         Cipher Suites Length → skip cipher suites
    ///         Compression Length → skip compression
    ///         Extensions Length → walk extensions looking for type 0x0000 (SNI)
    /// ```
    private func extractSNI(from data: Data) -> String? {
        guard data.count > 5 else { return nil }
        let bytes = [UInt8](data)

        // Must be a TLS Handshake record (0x16) with ClientHello (0x01)
        guard bytes[0] == 0x16 else { return nil }
        guard bytes.count > 5, bytes[5] == 0x01 else { return nil }

        // Skip fixed fields: ContentType(1) + Version(2) + Length(2)
        //   + HandshakeType(1) + Length(3) + Version(2) + Random(32) = 43
        var pos = 43
        guard pos < bytes.count else { return nil }

        // Skip Session ID (variable length: 1 byte length + N bytes)
        let sessionIDLen = Int(bytes[pos])
        pos += 1 + sessionIDLen
        guard pos + 2 <= bytes.count else { return nil }

        // Skip Cipher Suites (variable length: 2 byte length + N bytes)
        let cipherSuitesLen = Int(bytes[pos]) << 8 | Int(bytes[pos + 1])
        pos += 2 + cipherSuitesLen
        guard pos + 1 <= bytes.count else { return nil }

        // Skip Compression Methods (variable length: 1 byte length + N bytes)
        let compressionLen = Int(bytes[pos])
        pos += 1 + compressionLen
        guard pos + 2 <= bytes.count else { return nil }

        // Extensions block
        let extensionsLen = Int(bytes[pos]) << 8 | Int(bytes[pos + 1])
        pos += 2
        let extensionsEnd = min(pos + extensionsLen, bytes.count)

        // Walk through extensions looking for SNI (type 0x0000)
        while pos + 4 <= extensionsEnd {
            let extType = Int(bytes[pos]) << 8 | Int(bytes[pos + 1])
            let extLen = Int(bytes[pos + 2]) << 8 | Int(bytes[pos + 3])
            pos += 4

            if extType == 0x0000 {
                // SNI extension: list_length(2) + type(1) + name_length(2) + name
                guard pos + 5 <= extensionsEnd else { return nil }
                let nameLen = Int(bytes[pos + 3]) << 8 | Int(bytes[pos + 4])
                let nameStart = pos + 5
                guard nameStart + nameLen <= extensionsEnd else { return nil }
                return String(bytes: bytes[nameStart..<(nameStart + nameLen)], encoding: .ascii)
            }

            pos += extLen
        }
        return nil
    }

    // MARK: - HTTP Header Extraction

    /// Extract the Host header from a raw HTTP request.
    /// Only processes requests that start with a known HTTP method.
    ///
    /// Example input bytes: "GET /page HTTP/1.1\r\nHost: example.com\r\n..."
    /// Returns: "example.com"
    private func extractHTTPHost(from data: Data) -> String? {
        guard let str = String(data: data.prefix(512), encoding: .ascii) else { return nil }
        // Verify this looks like an HTTP request
        guard str.hasPrefix("GET ") || str.hasPrefix("POST ") || str.hasPrefix("HEAD ") ||
              str.hasPrefix("PUT ") || str.hasPrefix("DELETE ") || str.hasPrefix("CONNECT ") else {
            return nil
        }
        // Find "Host:" header line
        for line in str.components(separatedBy: "\r\n") {
            if line.lowercased().hasPrefix("host:") {
                let host = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                return host.components(separatedBy: ":").first  // Strip port if present
            }
        }
        return nil
    }

    /// Combine the HTTP Host header and request path into a full URL.
    /// Used for exception matching (e.g. "instagram.com/school-account").
    ///
    /// Example: "GET /school-account HTTP/1.1\r\nHost: instagram.com"
    /// Returns: "instagram.com/school-account"
    private func extractHTTPFullURL(from data: Data) -> String? {
        guard let str = String(data: data.prefix(512), encoding: .ascii) else { return nil }
        let lines = str.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else { return nil }

        // Extract path from "GET /path HTTP/1.1"
        let parts = requestLine.split(separator: " ")
        guard parts.count >= 2 else { return nil }
        let path = String(parts[1])

        // Find Host header and combine
        for line in lines {
            if line.lowercased().hasPrefix("host:") {
                let host = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                    .components(separatedBy: ":").first ?? ""
                return host + path
            }
        }
        return nil
    }
}
