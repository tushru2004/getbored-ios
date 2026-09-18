import Foundation
import GetBoredCore

    /// Effective iOS policy keeps explicit denies separate from whitelist entries.
    /// The persisted wire format remains the per-list v2 policy; this value is
    /// rebuilt at each decision so inactive lists contribute neither allows nor denies.
    public struct IOSLoadedFilterRules {
        public var siteRules: [SiteRule]
        public var filterMode: FilterMode
        public var exceptions: [String]
        public var allowedAppBundleIDs: [String]
        public var blockedAppBundleIDs: [String]
        public var explicitBlockedSites: [String] = []
    }

    /**
     * Shared, pure policy rules for the iOS filtering targets.
     *
     * Stores and providers collect iOS state, pass a `LoadedFilterRules` snapshot,
     * and apply the returned decision. `IOSDecisionCore` owns the matching and
     * precedence rules; it does not read App Group storage, touch NetworkExtension,
     * or write logs.
     */
    public enum IOSDecisionCore {}

    extension IOSDecisionCore {
        // MARK: - Shared Decision Results

        public enum PolicyDecisionKind: Equatable {
            case allow
            case block
        }

        public struct PolicyDecision {
            public let kind: PolicyDecisionKind
            public let reason: String
            public var blocked: Bool { kind == .block }
        }

        public struct FilterStatusViewModel {
            public let filterState: String
            public let filterLabel: String
            public let icloudState: String
            public let icloudLabel: String

            public func toDictionary() -> [String: String] {
                [
                    "filterState": filterState, "filterLabel": filterLabel,
                    "icloudState": icloudState, "icloudLabel": icloudLabel,
                ]
            }
        }

        public struct BlockedHostResolution {
            public let displayDomain: String
            public let rawEndpoint: String?
            public let resolutionSource: String
            public let isResolvableHostname: Bool
        }

        // MARK: - Filter Status

        /**
         * Call flow:
         *
         *   live filter state
         *       ├── error exists → error + message
         *       ├── value is nil → checking
         *       ├── enabled → active
         *       └── disabled → inactive
         *
         *   legacy iCloud state
         *       └── mapped separately for bridge compatibility
         */
        public static func filterStatusViewModel(
            filterEnabled: Bool?, filterErrorMessage: String?, icloudAvailable: Bool?,
            icloudErrorMessage: String?
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
                filterState: filter.0, filterLabel: filter.1, icloudState: cloud.0, icloudLabel: cloud.1
            )
        }

        // MARK: - Core URL and Host Policy

        public static func shouldBlock(_ url: String, using rules: IOSLoadedFilterRules) -> Bool {
            if isExplicitlyBlocked(url, using: rules) { return true }
            if matchesException(url, exceptions: rules.exceptions) { return false }
            let isListed = matchesSiteRule(url, siteRules: rules.siteRules.map(\.url))
            if rules.filterMode == .whiteList { return !isListed }
            return isListed
        }

        /**
         * Call flow:
         *
         *   host
         *       │
         *       ▼
         *   normalize
         *       ├── empty/system host → allow
         *       ├── allow-list mode → listed allows; unlisted blocks
         *       └── block-list mode → listed blocks; empty list allows
         */
        public static func classifyHost(
            _ host: String, using rules: IOSLoadedFilterRules, systemAllowedSuffixes: [String]
        ) -> PolicyDecision {
            let host = normalizeHost(host) ?? ""
            if host.isEmpty { return PolicyDecision(kind: .allow, reason: "Empty host") }
            if isSystemAllowed(host, systemAllowedSuffixes: systemAllowedSuffixes) {
                return PolicyDecision(kind: .allow, reason: "System allowed")
            }
            if isExplicitlyBlocked(host, using: rules) {
                return PolicyDecision(kind: .block, reason: "Explicit blocklist wins")
            }
            let isListed = matchesSiteRule(host, siteRules: rules.siteRules.map(\.url))
            if rules.filterMode == .whiteList {
                if isListed { return PolicyDecision(kind: .allow, reason: "In allowed list") }
                return PolicyDecision(kind: .block, reason: "Block everything mode")
            }
            if rules.siteRules.isEmpty {
                return PolicyDecision(kind: .allow, reason: "Empty blocklist")
            }
            if isListed { return PolicyDecision(kind: .block, reason: "In blocklist") }
            return PolicyDecision(kind: .allow, reason: "Not listed")
        }

        // MARK: - Rule Matching and Normalization

        public static func matchesAllowedApp(_ bundleID: String, using rules: IOSLoadedFilterRules) -> Bool {
            matchesAllowedApp(bundleID, allowedAppBundleIDs: rules.allowedAppBundleIDs)
        }
        public static func matchesAllowedApp(_ bundleID: String, allowedAppBundleIDs: [String]) -> Bool {
            matchesBundleID(bundleID, candidates: allowedAppBundleIDs)
        }
        public static func matchesSiteRule(_ url: String, using rules: IOSLoadedFilterRules) -> Bool {
            if rules.filterMode == .whiteList && isExplicitlyBlocked(url, using: rules) { return false }
            return matchesSiteRule(url, siteRules: rules.siteRules.map(\.url))
        }
        public static func isExplicitlyBlocked(_ url: String, using rules: IOSLoadedFilterRules) -> Bool {
            matchesSiteRule(url, siteRules: rules.explicitBlockedSites)
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
        public static func hostMatchesDomain(_ host: String, domain: String) -> Bool {
            guard let host = normalizeHost(host), let domain = normalizeHost(domain), !host.isEmpty,
                !domain.isEmpty
            else { return false }
            return host == domain || host.hasSuffix("." + domain)
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
        public static func matchesException(_ url: String, using rules: IOSLoadedFilterRules) -> Bool {
            !isExplicitlyBlocked(url, using: rules) && matchesException(url, exceptions: rules.exceptions)
        }
        public static func matchesException(_ url: String, exceptions: [String]) -> Bool {
            let url = normalizedURLPrefix(url)
            return exceptions.contains { exception in
                let pattern = normalizedURLPrefix(exception)
                return !pattern.isEmpty && url.hasPrefix(pattern)
            }
        }

        // MARK: - App Policy

        public static func shouldAllowApp(_ sourceApp: String, using rules: IOSLoadedFilterRules) -> Bool {
            let app = sourceApp.lowercased()
            if app.contains(GetBoredIdentifiers.bundlePrefix.lowercased()) { return true }
            if app.hasSuffix(".com.apple.")
                || (app.contains(".com.apple.") && !app.contains("mobilesafari"))
            {
                return true
            }
            return matchesAllowedApp(sourceApp, allowedAppBundleIDs: rules.allowedAppBundleIDs)
        }
        public static func isAppBlocked(_ sourceApp: String, using rules: IOSLoadedFilterRules) -> Bool {
            matchesBundleID(sourceApp, candidates: rules.blockedAppBundleIDs)
        }
        public static func shouldLogBlockedAppProbe(
            _ sourceApp: String?, using rules: IOSLoadedFilterRules
        ) -> Bool {
            guard let sourceApp, !sourceApp.isEmpty else { return false }
            return rules.filterMode == .whiteList && !shouldAllowApp(sourceApp, using: rules)
        }
        public static func isSystemAllowed(_ host: String, systemAllowedSuffixes: [String]) -> Bool {
            systemAllowedSuffixes.contains { hostMatchesDomain(host, domain: $0) }
        }

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
        // Internal only because blocked-host resolution is in its own source file.
        static func nonBlank(_ value: String?) -> String? {
            guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty
            else { return nil }
            return value
        }
    }
