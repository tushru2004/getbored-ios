import Foundation
import GetBoredCore

/// Shared, pure policy rules for the iOS filtering targets.
///
/// Stores and providers collect iOS state, pass a `LoadedFilterRules` snapshot,
/// and apply the returned decision. `IOSDecisionCore` owns the matching and
/// precedence rules; it does not read App Group storage, touch NetworkExtension,
/// or write logs.
public enum IOSDecisionCore {
    // MARK: - Decision Results

    public enum PolicyDecisionKind: Equatable {
        case allow
        case block
    }

    public struct PolicyDecision {
        public let kind: PolicyDecisionKind
        public let reason: String
        public var blocked: Bool { kind == .block }
    }

    public enum ParentChildDecisionKind: Equatable {
        case noActiveContext
        case staleActiveContext
        case matchActiveParent
        case matchActiveChild
        case noActiveMatch
    }

    public struct ParentChildDecision {
        public let kind: ParentChildDecisionKind
        public let host: String
        public let endpoint: String
        public let activeParent: String
        public let ageSeconds: TimeInterval
        public let childCount: Int
        public let event: String
        public let observationDecision: String
        public let shouldAllow: Bool
    }

    public struct FilterStatusViewModel {
        public let filterState: String
        public let filterLabel: String
        public let icloudState: String
        public let icloudLabel: String

        public func toDictionary() -> [String: String] {
            [
                "filterState": filterState, "filterLabel": filterLabel, "icloudState": icloudState,
                "icloudLabel": icloudLabel,
            ]
        }
    }

    public struct BlockedHostResolution {
        public let displayDomain: String
        public let rawEndpoint: String?
        public let resolutionSource: String
        public let isResolvableHostname: Bool
    }
    public struct ActivePageContext: Equatable {
        public let parentDomain: String
        public let childDomains: [String]
        public let url: String
        public let receivedAt: TimeInterval
    }
    public struct FlowObservation: Equatable {
        public let requestHost: String
        public let parentDomain: String
        public let decision: String
        public let endpoint: String
        public let observedAt: TimeInterval
    }
    public struct AllowedSafariParentDecision: Equatable {
        public let shouldAllow: Bool
        public let parentDomain: String
        public let requestHost: String
        public let age: TimeInterval
        public let event: String
    }
    public struct SafariRelayDecision {
        public let shouldRelay: Bool
        public let host: String
        public let primaryEvent: String
        public let outcomeEvent: String
        public let parentChildKind: ParentChildDecisionKind
        public let activeParent: String
        public let observationDecision: String
        public let shouldSaveFlowObservation: Bool
        public let shouldRefreshActiveContext: Bool
        public let refreshEvent: String
    }

    // MARK: - Filter Status

    /// Maps filter state to the stable status strings used by the app bridge.
    ///
    /// `FilterStatusModule.current()` supplies the live filter fields and keeps
    /// the older iCloud inputs as `nil` for compatibility. The bridge forwards
    /// only the filter values to JavaScript.
    ///
    /// ```text
    /// live filter state
    ///       │
    ///       ├── error exists → error + server-provided message
    ///       ├── value is nil → checking
    ///       ├── enabled      → active
    ///       └── disabled     → inactive
    ///
    /// legacy iCloud state
    ///       └── mapped separately for bridge compatibility
    /// ```
    public static func filterStatusViewModel(
        filterEnabled: Bool?, filterErrorMessage: String?, icloudAvailable: Bool?, icloudErrorMessage: String?
    ) -> FilterStatusViewModel {
        let filter: (String, String)
        if let error = filterErrorMessage {
            filter = ("error", error)
        } else if filterEnabled == nil {
            filter = ("checking", "Checking...")
        } else if filterEnabled == true {
            filter = ("active", "Active & Protecting")
        } else {
            filter = ("inactive", "Inactive")
        }

        let cloud: (String, String)
        if let error = icloudErrorMessage {
            cloud = ("unavailable", error)
        } else if icloudAvailable == nil {
            cloud = ("checking", "Checking...")
        } else if icloudAvailable == true {
            cloud = ("available", "Connected")
        } else {
            cloud = ("unavailable", "Not signed in")
        }
        return FilterStatusViewModel(
            filterState: filter.0, filterLabel: filter.1, icloudState: cloud.0, icloudLabel: cloud.1)
    }

    // MARK: - Core URL and Host Policy

    /// Applies exception and list rules to a URL.
    ///
    /// Exceptions always allow the URL. Otherwise, block-list mode blocks listed
    /// URLs while allow-list mode blocks URLs that are not listed.
    public static func shouldBlock(_ url: String, using rules: LoadedFilterRules) -> Bool {
        if matchesException(url, exceptions: rules.exceptions) { return false }

        let isListed = matchesSiteRule(url, siteRules: rules.siteRules.map(\.url))
        if rules.filterMode == .whiteList { return !isListed }
        return isListed
    }
    /// Applies the system allowlist, site rules, and optional Safari parent context.
    ///
    /// In block mode, listed hosts are blocked. In allow-list mode, listed hosts
    /// and children of an allowed Safari parent are allowed. Callers own reading
    /// the snapshot and enforcing the result.
    ///
    /// ```text
    /// host
    ///  │
    ///  ▼
    /// normalize
    ///  ├── empty/system host → allow
    ///  ├── allow-list mode
    ///  │      ├── listed or allowed Safari child → allow
    ///  │      └── otherwise → block
    ///  └── block-list mode
    ///         ├── no rules → allow
    ///         └── listed → block; otherwise allow
    /// ```
    public static func classifyHost(
        _ host: String, using rules: LoadedFilterRules, systemAllowedSuffixes: [String],
        allowedSafariParent: String?
    ) -> PolicyDecision {
        let host = normalizeHost(host) ?? ""
        if host.isEmpty { return PolicyDecision(kind: .allow, reason: "Empty host") }
        if isSystemAllowed(host, systemAllowedSuffixes: systemAllowedSuffixes) {
            return PolicyDecision(kind: .allow, reason: "System allowed")
        }
        let isListed = matchesSiteRule(host, siteRules: rules.siteRules.map(\.url))
        if rules.filterMode == .whiteList {
            if isListed { return PolicyDecision(kind: .allow, reason: "In allowed list") }
            if let parent = nonBlank(allowedSafariParent) {
                return PolicyDecision(kind: .allow, reason: "Child of allowed Safari parent \(parent)")
            }
            return PolicyDecision(kind: .block, reason: "Block everything mode")
        }

        if rules.siteRules.isEmpty { return PolicyDecision(kind: .allow, reason: "Empty blocklist") }
        if isListed { return PolicyDecision(kind: .block, reason: "In blocklist") }
        return PolicyDecision(kind: .allow, reason: "Not listed")
    }

    // MARK: - Rule Matching and Normalization

    public static func matchesAllowedApp(_ bundleID: String, using rules: LoadedFilterRules) -> Bool {
        matchesAllowedApp(bundleID, allowedAppBundleIDs: rules.allowedAppBundleIDs)
    }
    public static func matchesAllowedApp(_ bundleID: String, allowedAppBundleIDs: [String]) -> Bool {
        matchesBundleID(bundleID, candidates: allowedAppBundleIDs)
    }
    public static func matchesSiteRule(_ url: String, using rules: LoadedFilterRules) -> Bool {
        matchesSiteRule(url, siteRules: rules.siteRules.map(\.url))
    }
    public static func matchesSiteRule(_ url: String, siteRules: [String]) -> Bool {
        siteRules.contains { hostMatchesDomain(url, domain: $0) }
    }
    public static func normalizeHost(_ value: String?) -> String? {
        guard var value else { return nil }
        value = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let range = value.range(of: "://") { value = String(value[range.upperBound...]) }
        for delimiter: Character in ["/", ":", "?"] {
            if let index = value.firstIndex(of: delimiter) { value = String(value[..<index]) }
        }
        return value.trimmingCharacters(in: CharacterSet(charactersIn: "."))
    }
    public static func normalizeChildPattern(_ value: String?) -> String? {
        guard let value else { return nil }
        let result = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if result.hasPrefix("*.") {
            return "*." + String(result.dropFirst(2)).trimmingCharacters(in: CharacterSet(charactersIn: "."))
        }
        return result.trimmingCharacters(in: CharacterSet(charactersIn: "."))
    }
    public static func hostMatchesDomain(_ host: String, domain: String) -> Bool {
        guard let host = normalizeHost(host), let domain = normalizeHost(domain), !host.isEmpty,
            !domain.isEmpty
        else { return false }
        return host == domain || host.hasSuffix("." + domain)
    }
    public static func hostMatchesChildPattern(_ host: String, childPattern: String) -> Bool {
        guard let pattern = normalizeChildPattern(childPattern), !pattern.isEmpty else { return false }
        if pattern.hasPrefix("*.") { return hostMatchesDomain(host, domain: String(pattern.dropFirst(2))) }
        return hostMatchesDomain(host, domain: pattern)
    }
    public static func baseKeyword(_ domainOrUrl: String) -> String {
        let parts = (normalizeHost(domainOrUrl) ?? "").split(separator: ".")
        guard parts.count >= 2 else { return "" }
        let keyword = String(parts[parts.count - 2])
        guard keyword.count >= 4 else { return "" }
        return keyword
    }
    public static func hostContainsAnyRelatedKeyword(_ host: String, domains: [String]) -> Bool {
        let host = normalizeHost(host) ?? ""
        return domains.contains {
            let key = baseKeyword($0)
            return !key.isEmpty && host.contains(key)
        }
    }
    public static func matchesException(_ url: String, using rules: LoadedFilterRules) -> Bool {
        matchesException(url, exceptions: rules.exceptions)
    }
    public static func matchesException(_ url: String, exceptions: [String]) -> Bool {
        let url = normalizedURLPrefix(url)
        return exceptions.contains { exception in
            let pattern = normalizedURLPrefix(exception)
            return !pattern.isEmpty && url.hasPrefix(pattern)
        }
    }

    // MARK: - App Policy

    public static func shouldAllowApp(_ sourceApp: String, using rules: LoadedFilterRules) -> Bool {
        let app = sourceApp.lowercased()
        if app.contains(GetBoredIdentifiers.bundlePrefix.lowercased()) { return true }
        if app.hasSuffix(".com.apple.") || (app.contains(".com.apple.") && !app.contains("mobilesafari")) {
            return true
        }
        return matchesAllowedApp(sourceApp, allowedAppBundleIDs: rules.allowedAppBundleIDs)
    }
    public static func isAppBlocked(_ sourceApp: String, using rules: LoadedFilterRules) -> Bool {
        matchesBundleID(sourceApp, candidates: rules.blockedAppBundleIDs)
    }
    public static func shouldLogBlockedAppProbe(_ sourceApp: String?, using rules: LoadedFilterRules) -> Bool
    {
        guard let sourceApp, !sourceApp.isEmpty else { return false }
        return rules.filterMode == .whiteList && !shouldAllowApp(sourceApp, using: rules)
    }
    public static func isSystemAllowed(_ host: String, systemAllowedSuffixes: [String]) -> Bool {
        systemAllowedSuffixes.contains { hostMatchesDomain(host, domain: $0) }
    }

    // MARK: - Protocol Inspection

    /// Extracts the server name from a TLS ClientHello without consuming the flow.
    ///
    /// Only the first 512 bytes are inspected. Any truncated or unexpected field
    /// returns `nil` so the caller can fall back to another source.
    ///
    /// ```text
    /// TLS bytes
    ///    │
    ///    ▼
    /// verify ClientHello
    ///    ▼
    /// skip session ID → cipher suites → compression methods
    ///    ▼
    /// scan extensions ×N
    ///    ├── server-name extension → decode hostname
    ///    └── missing/truncated data → nil
    /// ```
    public static func extractSNI(from data: Data) -> String? {
        let bytes = Array(data.prefix(512))
        let isTLSClientHello = bytes.count > 5 && bytes[0] == 0x16 && bytes[5] == 0x01
        guard isTLSClientHello else { return nil }

        var cursor = 43
        guard cursor < bytes.count else { return nil }

        let sessionIDLength = Int(bytes[cursor])
        cursor += 1 + sessionIDLength
        guard cursor + 2 <= bytes.count else { return nil }

        let cipherSuitesLength = Int(bytes[cursor]) * 256 + Int(bytes[cursor + 1])
        cursor += 2 + cipherSuitesLength
        guard cursor < bytes.count else { return nil }

        let compressionMethodsLength = Int(bytes[cursor])
        cursor += 1 + compressionMethodsLength
        guard cursor + 2 <= bytes.count else { return nil }

        let extensionsLength = Int(bytes[cursor]) * 256 + Int(bytes[cursor + 1])
        cursor += 2
        let extensionsEnd = min(bytes.count, cursor + extensionsLength)

        while cursor + 4 <= extensionsEnd {
            let extensionType = Int(bytes[cursor]) * 256 + Int(bytes[cursor + 1])
            let extensionLength = Int(bytes[cursor + 2]) * 256 + Int(bytes[cursor + 3])
            cursor += 4

            if extensionType == 0 {
                guard cursor + 5 <= extensionsEnd else { return nil }

                let serverNameLength = Int(bytes[cursor + 3]) * 256 + Int(bytes[cursor + 4])
                let serverNameStart = cursor + 5
                guard serverNameStart + serverNameLength <= extensionsEnd else { return nil }
                return String(
                    decoding: bytes[serverNameStart..<(serverNameStart + serverNameLength)], as: UTF8.self)
            }
            cursor += extensionLength
        }
        return nil
    }

    /// Extracts the `Host` header from the first 512 bytes of a plain HTTP request.
    /// Encrypted or unrecognized payloads return `nil`.
    public static func extractHTTPHost(from data: Data) -> String? {
        guard let text = String(data: data.prefix(512), encoding: .ascii), isHTTPRequest(text) else {
            return nil
        }
        return text.split(whereSeparator: \.isNewline).first { $0.lowercased().hasPrefix("host:") }.flatMap {
            String($0.dropFirst(5)).trimmingCharacters(in: .whitespacesAndNewlines).split(
                separator: ":", maxSplits: 1
            ).first.map(String.init)
        }
    }

    /// Combines an HTTP request target with its `Host` header for rule matching.
    public static func extractHTTPFullURL(from data: Data) -> String? {
        guard let text = String(data: data.prefix(512), encoding: .ascii), isHTTPRequest(text),
            let request = text.split(whereSeparator: \.isNewline).first
        else { return nil }
        let parts = request.split(separator: " ")
        guard parts.count >= 2, let host = extractHTTPHost(from: data) else { return nil }
        return host + String(parts[1])
    }

    // MARK: - Blocked Host Resolution

    /// Chooses the best user-facing identity for a blocked flow.
    ///
    /// ```text
    /// URL host → socket endpoint → source-app fallback → unknown marker
    ///    │              │                  │
    ///    └── first resolvable hostname wins ┘
    /// ```
    public static func resolveBlockedHost(rawURLHost: String?, rawEndpoint: String?, sourceApp: String?)
        -> BlockedHostResolution
    {
        let normalizedURLHost = normalizedBlockedHost(rawURLHost)
        let normalizedEndpoint = normalizedBlockedHost(rawEndpoint)

        if let host = normalizedURLHost, isResolvableHost(host) {
            return BlockedHostResolution(
                displayDomain: host, rawEndpoint: normalizedEndpoint, resolutionSource: "url-host",
                isResolvableHostname: true)
        }
        if let host = normalizedEndpoint, isResolvableHost(host) {
            return BlockedHostResolution(
                displayDomain: host, rawEndpoint: normalizedEndpoint, resolutionSource: "socket-endpoint",
                isResolvableHostname: true)
        }
        let sourceAppFallback = nonBlank(sourceApp).map { "app:\($0)" }
        let displayDomain =
            sourceAppFallback ?? normalizedURLHost ?? normalizedEndpoint ?? "unknown-blocked-flow"
        let resolutionSource: String
        if sourceApp == nil {
            resolutionSource = "unresolved"
        } else {
            resolutionSource = "source-app-fallback"
        }

        return BlockedHostResolution(
            displayDomain: displayDomain, rawEndpoint: normalizedEndpoint ?? normalizedURLHost,
            resolutionSource: resolutionSource, isResolvableHostname: false)
    }

    // MARK: - Safari App Proxy Decisions

    /// Decides whether the Safari App Proxy spike should relay one endpoint.
    ///
    /// The provider supplies the current page context and performs the returned
    /// side effects: event logging, context refresh, and flow observation storage.
    ///
    /// ```text
    /// endpoint
    ///    │
    ///    ├── unsupported endpoint → do not relay
    ///    ▼
    /// classify host without parent context
    ///    ├── directly allowed → relay; optionally refresh active context
    ///    └── otherwise
    ///           ▼
    ///       compare with active Safari parent and children
    ///           ├── child match → relay + save observation
    ///           └── other result → relay + record diagnostic outcome
    /// ```
    public static func safariRelayDecision(
        endpoint: String, using rules: LoadedFilterRules, systemAllowedSuffixes: [String],
        activeParent: String?, activeChildren: [String], activeContextAge: TimeInterval,
        activeContextMaxAge: TimeInterval, activeContextRefreshMinAge: TimeInterval
    ) -> SafariRelayDecision {
        guard let host = endpointHost(endpoint) else {
            return SafariRelayDecision(
                shouldRelay: false, host: "", primaryEvent: "BLOCK_UNSUPPORTED_ENDPOINT endpoint=\(endpoint)",
                outcomeEvent: "", parentChildKind: .noActiveContext, activeParent: "",
                observationDecision: "unsupportedEndpoint", shouldSaveFlowObservation: false,
                shouldRefreshActiveContext: false, refreshEvent: "")
        }
        if !classifyHost(
            host, using: rules, systemAllowedSuffixes: systemAllowedSuffixes, allowedSafariParent: nil
        ).blocked {
            let parent = activeParent ?? ""
            let matchingRule = rules.siteRules.map(\.url).compactMap(normalizeHost).first {
                hostMatchesDomain(parent, domain: $0)
            }

            let isOldEnoughToRefresh = activeContextAge > activeContextRefreshMinAge
            let shouldRefreshActiveContext: Bool
            if let matchingRule {
                shouldRefreshActiveContext =
                    isOldEnoughToRefresh && hostMatchesDomain(host, domain: matchingRule)
            } else {
                shouldRefreshActiveContext = false
            }

            let refreshEvent: String
            if shouldRefreshActiveContext, let matchingRule {
                refreshEvent =
                    "APP_PROXY_REFRESH_ACTIVE_CONTEXT rule=\(matchingRule) age=\(rounded(activeContextAge)) host=\(host) parent=\(parent)"
            } else {
                refreshEvent = ""
            }

            return SafariRelayDecision(
                shouldRelay: true, host: host,
                primaryEvent: "APP_PROXY_ALLOW_DIRECT host=\(host) endpoint=\(endpoint)", outcomeEvent: "",
                parentChildKind: .matchActiveParent, activeParent: parent, observationDecision: "directAllow",
                shouldSaveFlowObservation: false, shouldRefreshActiveContext: shouldRefreshActiveContext,
                refreshEvent: refreshEvent)
        }
        let result = parentChildDecision(
            host: host, endpoint: endpoint, parent: activeParent, children: activeChildren,
            age: activeContextAge, maxAge: activeContextMaxAge)
        let outcome: String
        switch result.kind {
        case .matchActiveParent: outcome = "APP_PROXY_ALLOW_ACTIVE_PARENT host=\(host) endpoint=\(endpoint)"
        case .matchActiveChild:
            outcome =
                "APP_PROXY_ALLOW_ACTIVE_CHILD host=\(host) parent=\(result.activeParent) endpoint=\(endpoint)"
        default:
            outcome =
                "APP_PROXY_ALLOW_UNCLASSIFIED host=\(host) decision=\(result.observationDecision) endpoint=\(endpoint)"
        }
        return SafariRelayDecision(
            shouldRelay: true, host: host, primaryEvent: result.event, outcomeEvent: outcome,
            parentChildKind: result.kind, activeParent: result.activeParent,
            observationDecision: result.observationDecision,
            shouldSaveFlowObservation: result.kind == .matchActiveChild, shouldRefreshActiveContext: false,
            refreshEvent: "")
    }

    // MARK: - Safari Parent-Child Context

    /// Normalizes one Safari page context before it is stored.
    /// Children are deduplicated, sorted, and never include the parent itself.
    public static func normalizedActivePageContext(
        parentDomain: String?, childDomains: [String], url: String, receivedAtSwiftRefSeconds: Double
    ) -> ActivePageContext? {
        guard let parent = normalizeHost(parentDomain), !parent.isEmpty else { return nil }
        return ActivePageContext(
            parentDomain: parent,
            childDomains: Array(
                Set(childDomains.compactMap(normalizeHost).filter { !$0.isEmpty && $0 != parent })
            ).sorted(), url: url, receivedAt: receivedAtSwiftRefSeconds)
    }

    /// Decodes the former loose JSON payload and converts it to the typed context.
    public static func activePageContextFromLegacyPayloadJSON(
        _ json: String?, receivedAtSwiftRefSeconds: Double
    ) -> ActivePageContext? {
        guard let values = jsonObject(json) as? [String: Any], let parent = values["parentDomain"] as? String
        else { return nil }
        return normalizedActivePageContext(
            parentDomain: parent, childDomains: values["childDomains"] as? [String] ?? [],
            url: values["url"] as? String ?? "", receivedAtSwiftRefSeconds: receivedAtSwiftRefSeconds)
    }
    public static func normalizedFlowObservation(
        requestHost: String?, parentDomain: String?, decision: String, endpoint: String,
        observedAtSwiftRefSeconds: Double
    ) -> FlowObservation? {
        guard let host = normalizeHost(requestHost), !host.isEmpty, let parent = normalizeHost(parentDomain),
            !parent.isEmpty
        else { return nil }
        return FlowObservation(
            requestHost: host, parentDomain: parent, decision: decision, endpoint: endpoint,
            observedAt: observedAtSwiftRefSeconds)
    }
    public static func shouldClearActiveContext(activeContextJson: String?, clearingParent: String?) -> Bool {
        guard let context = decodeContext(activeContextJson), let parent = normalizeHost(clearingParent),
            !parent.isEmpty
        else { return true }
        return context.parentDomain == parent
    }

    /// Verifies that a recently observed child still belongs to an allowed Safari parent.
    ///
    /// ```text
    /// request host + saved observation
    ///       │
    ///       ├── observation is missing/not a child match → no decision
    ///       ▼
    /// validate age and active parent context
    ///       │
    ///       ▼
    /// confirm host in merged child set
    ///       │
    ///       ├── parent is listed → allow child
    ///       └── parent is not listed → reject child
    /// ```
    public static func allowedSafariParentForChild(
        flowObservationJson: String?, activeContextJson: String?, parentChildMapJson: String?,
        registryJson: String?, requestHost: String, maxAgeSeconds: Double, nowEpochSeconds: Double,
        using rules: LoadedFilterRules
    ) -> AllowedSafariParentDecision? {
        guard let host = normalizeHost(requestHost), !host.isEmpty,
            let observation = decodeObservation(flowObservationJson),
            observation.decision == "matchActiveChild",
            hostMatchesDomain(host, domain: observation.requestHost)
        else { return nil }
        let age = nowEpochSeconds - observation.observedAt
        guard age >= 0, age <= maxAgeSeconds, let context = decodeContext(activeContextJson),
            context.parentDomain == observation.parentDomain,
            parentChildMergedChildren(
                parentChildMapJson: parentChildMapJson, activeContextJson: activeContextJson,
                registryJson: registryJson, parentDomain: observation.parentDomain
            ).contains(where: { hostMatchesChildPattern(host, childPattern: $0) })
        else { return nil }
        let allowed = matchesSiteRule(observation.parentDomain, siteRules: rules.siteRules.map(\.url))
        let event: String
        if allowed {
            event =
                "DATA_PROVIDER_ALLOW_CHILD host=\(host) parent=\(observation.parentDomain) age=\(rounded(age))"
        } else {
            event =
                "DATA_PROVIDER_REJECT_CHILD_PARENT_NOT_ALLOWLISTED host=\(host) parent=\(observation.parentDomain) age=\(rounded(age))"
        }
        return AllowedSafariParentDecision(
            shouldAllow: allowed, parentDomain: observation.parentDomain, requestHost: host, age: age,
            event: event)
    }
    public static func parentChildAppendEvent(
        existingEvents: [String], timestamp: String, event: String, maxEvents: Int
    ) -> [String] { Array((existingEvents + ["\(timestamp) \(event)"]).suffix(max(0, maxEvents))) }
    /// Resolves known children for a parent.
    ///
    /// A non-empty static map is authoritative. Without one, the method combines
    /// the current Safari page context with children learned by the proxy.
    ///
    /// ```text
    /// normalized parent
    ///       │
    ///       ├── static map has children → return static children
    ///       └── otherwise → active-context children + learned registry children
    /// ```
    public static func parentChildMergedChildren(
        parentChildMapJson: String?, activeContextJson: String?, registryJson: String?, parentDomain: String
    ) -> Set<String> {
        guard let parent = normalizeHost(parentDomain), !parent.isEmpty else { return [] }
        if let staticChildren = mapChildren(parentChildMapJson, parent: parent), !staticChildren.isEmpty {
            return staticChildren
        }
        var result = Set<String>()
        if let context = decodeContext(activeContextJson), context.parentDomain == parent {
            result.formUnion(context.childDomains)
        }
        result.formUnion(registry(registryJson)[parent] ?? [])
        return result
    }

    /// Merges normalized child domains into the learned registry JSON.
    /// Invalid input preserves the previous JSON rather than erasing learned data.
    public static func parentChildUpdatedRegistryJSON(
        registryJson: String?, parentDomain: String, childDomains: [String]
    ) -> String? {
        guard let parent = normalizeHost(parentDomain), !parent.isEmpty else { return registryJson }
        var entries = registry(registryJson)
        entries[parent, default: []].formUnion(
            childDomains.compactMap(normalizeHost).filter { !$0.isEmpty && $0 != parent })
        let object = entries.mapValues { Array($0).sorted() }
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else {
            return registryJson
        }
        return String(data: data, encoding: .utf8)
    }
    public static func isValidParentChildMapJSON(_ json: String) -> Bool { decodeMap(json) != nil }
    public static func parentChildLegacyPayload(
        parentDomain: String, childDomains: [String], url: String, receivedAtSwiftRefSeconds: Double
    ) -> [String: Any] {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return [
            "type": "getbored.childRegistrationProbe", "url": url, "parentDomain": parentDomain,
            "childDomains": childDomains, "source": "safari-extension",
            "receivedAt": formatter.string(
                from: Date(timeIntervalSinceReferenceDate: floor(receivedAtSwiftRefSeconds))),
        ]
    }

    // MARK: - Activity Log Helpers

    public static func activityLogStripTeamID(_ identifier: String?) -> String? {
        guard let identifier, !identifier.isEmpty else { return nil }
        let prefixes = [
            "com.", "org.", "net.", "de.", "io.", "me.", "app.", "co.", "uk.", "fr.", "jp.", "au.", "at.",
        ]
        for prefix in prefixes {
            if let index = identifier.range(of: prefix)?.lowerBound { return String(identifier[index...]) }
        }
        let parts = identifier.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count >= 3, parts[0].count >= 8, parts[0].allSatisfy({ $0.isUppercase || $0.isNumber })
        else { return identifier }
        return parts.dropFirst().joined(separator: ".")
    }

    /// Prepends new activity entries and enforces storage limits only when needed.
    /// Entries are first capped per source app, then capped to the total limit.
    public static func activityLogMergeAndTrim(
        existing: [GetBoredCore.ActivityLogEntry], newEntries: [GetBoredCore.ActivityLogEntry],
        maxTotal: Int = 500, maxPerApp: Int = 50
    ) -> [GetBoredCore.ActivityLogEntry] {
        let all = newEntries + existing
        guard all.count > maxTotal else { return all }
        var counts: [String: Int] = [:]
        let capped = all.filter { entry in
            let key = entry.sourceApp?.lowercased() ?? "__nil__"
            let count = counts[key, default: 0]
            guard count < maxPerApp else { return false }
            counts[key] = count + 1
            return true
        }
        return Array(capped.prefix(max(0, maxTotal)))
    }

    // MARK: - Persisted Payloads

    private struct Context: Codable {
        let parentDomain: String
        let childDomains: [String]
        let url: String
        let receivedAt: Double
    }
    private struct Observation: Codable {
        let requestHost: String
        let parentDomain: String
        let decision: String
        let endpoint: String
        let observedAt: Double
    }
    private struct Map: Decodable {
        let schemaVersion: Int
        let rules: [Rule]
        let wildcards: [Wildcard]?
    }
    private struct Rule: Decodable {
        let p: String
        let c: [String]
    }
    private struct Wildcard: Decodable {
        let p: String
        let c: String
    }

    // MARK: - Private Matching Helpers

    private static func normalizedURLPrefix(_ value: String) -> String {
        var value = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let range = value.range(of: "://") { value = String(value[range.upperBound...]) }
        if value.hasPrefix("www.") { value.removeFirst(4) }
        return value
    }
    private static func matchesBundleID(_ id: String, candidates: [String]) -> Bool {
        let id = id.lowercased()
        return candidates.contains {
            let value = $0.lowercased()
            return id == value || id.hasSuffix("." + value)
        }
    }
    private static func nonBlank(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return nil
        }
        return value
    }
    private static func isHTTPRequest(_ value: String) -> Bool {
        ["GET ", "POST ", "PUT ", "DELETE ", "HEAD ", "CONNECT "].contains { value.hasPrefix($0) }
    }
    private static func normalizedBlockedHost(_ raw: String?) -> String? {
        guard let host = normalizeHost(raw), !host.isEmpty, host != "unknown" else { return nil }
        return host
    }
    private static func isResolvableHost(_ host: String) -> Bool { !host.hasPrefix("app:") && !isIP(host) }
    private static func isIP(_ host: String) -> Bool {
        let normalized = host.trimmingCharacters(in: CharacterSet(charactersIn: "[] .")).lowercased()
        let v4 = normalized.split(separator: ".")
        if v4.count == 4 && v4.allSatisfy({ Int($0).map { 0...255 ~= $0 } ?? false }) { return true }
        let v6 = normalized.split(separator: ":", omittingEmptySubsequences: false)
        return v6.count > 1 && v6.allSatisfy { $0.isEmpty || ($0.count <= 4 && $0.allSatisfy(\.isHexDigit)) }
    }
    private static func endpointHost(_ endpoint: String) -> String? {
        let token = endpoint.split(separator: " ", maxSplits: 1).first.map(String.init) ?? ""
        guard let colon = token.firstIndex(of: ":") else { return nil }
        return normalizeHost(String(token[..<colon])).flatMap { $0.isEmpty ? nil : $0 }
    }
    private static func rounded(_ value: TimeInterval) -> String { String((value * 10).rounded() / 10) }

    // MARK: - Private Safari Decision Helpers

    /// Applies active-page precedence to a host that was not directly allowed.
    ///
    /// ```text
    /// active context
    ///      ├── missing → no active context
    ///      ├── expired → stale context
    ///      ├── host matches parent → allow parent
    ///      ├── host matches child pattern → allow child
    ///      └── otherwise → no active match
    /// ```
    private static func parentChildDecision(
        host: String, endpoint: String, parent: String?, children: [String], age: TimeInterval,
        maxAge: TimeInterval
    ) -> ParentChildDecision {
        guard let parent = normalizeHost(parent), !parent.isEmpty else {
            return ParentChildDecision(
                kind: .noActiveContext, host: host, endpoint: endpoint, activeParent: "", ageSeconds: 0,
                childCount: 0, event: "BLOCK_NO_CONTEXT host=\(host) endpoint=\(endpoint)",
                observationDecision: "noActiveContext", shouldAllow: false)
        }
        let count = children.count
        if age > maxAge {
            return ParentChildDecision(
                kind: .staleActiveContext, host: host, endpoint: endpoint, activeParent: parent,
                ageSeconds: age, childCount: count,
                event: "BLOCK_STALE host=\(host) activeParent=\(parent) age=\(rounded(age))",
                observationDecision: "staleActiveContext", shouldAllow: false)
        }
        if hostMatchesDomain(host, domain: parent) {
            return ParentChildDecision(
                kind: .matchActiveParent, host: host, endpoint: endpoint, activeParent: parent,
                ageSeconds: age, childCount: count,
                event: "ALLOW_PARENT host=\(host) parent=\(parent) age=\(rounded(age))",
                observationDecision: "matchActiveParent", shouldAllow: true)
        }
        if children.contains(where: { hostMatchesChildPattern(host, childPattern: $0) }) {
            return ParentChildDecision(
                kind: .matchActiveChild, host: host, endpoint: endpoint, activeParent: parent,
                ageSeconds: age, childCount: count,
                event: "ALLOW_CHILD host=\(host) parent=\(parent) age=\(rounded(age))",
                observationDecision: "matchActiveChild", shouldAllow: true)
        }
        return ParentChildDecision(
            kind: .noActiveMatch, host: host, endpoint: endpoint, activeParent: parent, ageSeconds: age,
            childCount: count,
            event:
                "BLOCK_NO_MATCH host=\(host) activeParent=\(parent) childCount=\(count) age=\(rounded(age))",
            observationDecision: "noActiveMatch", shouldAllow: false)
    }

    // MARK: - JSON Decoding

    private static func jsonObject(_ json: String?) -> Any? {
        guard let json, let data = json.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data)
    }
    private static func decodeContext(_ json: String?) -> ActivePageContext? {
        guard let json, let data = json.data(using: .utf8),
            let context = try? JSONDecoder().decode(Context.self, from: data)
        else { return nil }
        return ActivePageContext(
            parentDomain: context.parentDomain, childDomains: context.childDomains, url: context.url,
            receivedAt: context.receivedAt)
    }
    private static func decodeObservation(_ json: String?) -> FlowObservation? {
        guard let json, let data = json.data(using: .utf8),
            let observation = try? JSONDecoder().decode(Observation.self, from: data)
        else { return nil }
        return FlowObservation(
            requestHost: observation.requestHost, parentDomain: observation.parentDomain,
            decision: observation.decision, endpoint: observation.endpoint, observedAt: observation.observedAt
        )
    }
    private static func decodeMap(_ json: String?) -> Map? {
        guard let json, let data = json.data(using: .utf8),
            let map = try? JSONDecoder().decode(Map.self, from: data), map.schemaVersion == 1
        else { return nil }
        return map
    }
    private static func mapChildren(_ json: String?, parent: String) -> Set<String>? {
        guard let map = decodeMap(json) else { return nil }
        var result = Set<String>()
        for rule in map.rules where hostMatchesDomain(parent, domain: rule.p) {
            result.formUnion(rule.c.compactMap(normalizeChildPattern).filter { !$0.isEmpty })
        }
        for rule in map.wildcards ?? [] where hostMatchesDomain(parent, domain: rule.p) {
            if let child = normalizeChildPattern(rule.c), !child.isEmpty { result.insert(child) }
        }
        return result
    }
    private static func registry(_ json: String?) -> [String: Set<String>] {
        guard let object = jsonObject(json) as? [String: Any] else { return [:] }
        var result: [String: Set<String>] = [:]
        for (key, value) in object {
            guard let parent = normalizeHost(key), !parent.isEmpty, let values = value as? [String] else {
                continue
            }
            result[parent] = Set(values.compactMap(normalizeHost).filter { !$0.isEmpty && $0 != parent })
        }
        return result
    }
}
