import Foundation
import GetBoredCore

#if canImport(GetBoredSharedCore)
import GetBoredSharedCore
#endif

/// Adapter seam for the Kotlin DecisionCore POC.
///
/// The production version of this file should be the only Swift code that
/// knows about the generated `GetBoredSharedCore` Kotlin/Native framework. That
/// keeps NetworkExtension providers Swift-owned while allowing policy logic to
/// move behind a Kotlin-owned boundary.
public enum KMPDecisionCoreAdapter {
    public enum PolicyDecisionKind {
        case allow
        case block
    }

    public struct PolicyDecision {
        public let kind: PolicyDecisionKind
        public let reason: String

        public var blocked: Bool {
            kind == .block
        }
    }

    public enum ParentChildDecisionKind {
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

    public static func shouldBlock(_ url: String, using loadedFilterRules: LoadedFilterRules) -> Bool {
        #if canImport(GetBoredSharedCore)
        return GetBoredSharedCore.DecisionCore().shouldBlock(
            url: url,
            siteRules: loadedFilterRules.siteRules.map(\.url),
            filterModeRaw: loadedFilterRules.filterMode.rawValue,
            exceptions: loadedFilterRules.exceptions
        )
        #else
        if matchesException(url, using: loadedFilterRules) {
            return false
        }
        let matchedSiteRule = GetBoredCore.DecisionCore.matchesSiteRule(url, using: loadedFilterRules)
        return loadedFilterRules.filterMode == .whiteList ? !matchedSiteRule : matchedSiteRule
        #endif
    }

    public static func classifyHost(
        _ host: String,
        using loadedFilterRules: LoadedFilterRules,
        systemAllowedSuffixes: [String],
        allowedSafariParent: String?
    ) -> PolicyDecision {
        #if canImport(GetBoredSharedCore)
        let decision = GetBoredSharedCore.DecisionCore().classifyHost(
            host: host,
            policy: kotlinPolicySnapshot(from: loadedFilterRules, systemAllowedSuffixes: systemAllowedSuffixes),
            allowedSafariParent: allowedSafariParent
        )
        return PolicyDecision(
            kind: decision.kind == GetBoredSharedCore.PolicyDecisionKind.block ? .block : .allow,
            reason: decision.reason
        )
        #else
        let normalizedHost = normalizedHost(host)
        if normalizedHost.isEmpty {
            return PolicyDecision(kind: .allow, reason: "Empty host")
        }
        if isSystemAllowed(host, systemAllowedSuffixes: systemAllowedSuffixes) {
            return PolicyDecision(kind: .allow, reason: "System allowed")
        }
        if loadedFilterRules.filterMode == .whiteList {
            if GetBoredCore.DecisionCore.matchesSiteRule(host, using: loadedFilterRules) {
                return PolicyDecision(kind: .allow, reason: "In allowed list")
            }
            if let allowedSafariParent, !allowedSafariParent.isEmpty {
                return PolicyDecision(kind: .allow, reason: "Child of allowed Safari parent \(allowedSafariParent)")
            }
            return PolicyDecision(kind: .block, reason: "Block everything mode")
        }
        if loadedFilterRules.siteRules.isEmpty {
            return PolicyDecision(kind: .block, reason: "No entries (lockdown)")
        }
        if GetBoredCore.DecisionCore.matchesSiteRule(host, using: loadedFilterRules) {
            return PolicyDecision(kind: .block, reason: "In blocklist")
        }
        return PolicyDecision(kind: .allow, reason: "Not listed")
        #endif
    }

    public static func matchesAllowedApp(_ bundleID: String, using loadedFilterRules: LoadedFilterRules) -> Bool {
        #if canImport(GetBoredSharedCore)
        return GetBoredSharedCore.DecisionCore().matchesAllowedApp(
            bundleId: bundleID,
            allowedAppBundleIds: loadedFilterRules.allowedAppBundleIDs
        )
        #else
        return GetBoredCore.DecisionCore.matchesAllowedApp(bundleID, using: loadedFilterRules)
        #endif
    }

    public static func matchesSiteRule(_ url: String, using loadedFilterRules: LoadedFilterRules) -> Bool {
        #if canImport(GetBoredSharedCore)
        return GetBoredSharedCore.DecisionCore().matchesSiteRule(
            url: url,
            siteRules: loadedFilterRules.siteRules.map(\.url)
        )
        #else
        return GetBoredCore.DecisionCore.matchesSiteRule(url, using: loadedFilterRules)
        #endif
    }

    public static func normalizeHost(_ value: String?) -> String? {
        guard let value else { return nil }
        #if canImport(GetBoredSharedCore)
        return GetBoredSharedCore.DecisionCore().normalizeHost(input: value)
        #else
        return normalizedHost(value)
        #endif
    }

    public static func normalizeChildPattern(_ value: String?) -> String? {
        guard let value else { return nil }
        #if canImport(GetBoredSharedCore)
        return GetBoredSharedCore.DecisionCore().normalizeChildPattern(input: value)
        #else
        let trimmed = value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .trimmingCharacters(in: CharacterSet(charactersIn: "."))
        guard !trimmed.isEmpty else { return "" }
        if trimmed.hasPrefix("*.") {
            let suffix = String(trimmed.dropFirst(2)).trimmingCharacters(in: CharacterSet(charactersIn: "."))
            return suffix.isEmpty ? "" : "*.\(suffix)"
        }
        return trimmed
        #endif
    }

    public static func hostMatchesDomain(_ host: String, domain: String) -> Bool {
        #if canImport(GetBoredSharedCore)
        return GetBoredSharedCore.DecisionCore().hostMatchesDomain(hostOrUrl: host, domainOrUrl: domain)
        #else
        let normalizedHost = normalizedHost(host)
        let normalizedDomain = normalizedHost(domain)
        guard !normalizedHost.isEmpty, !normalizedDomain.isEmpty else { return false }
        return normalizedHost == normalizedDomain || normalizedHost.hasSuffix(".\(normalizedDomain)")
        #endif
    }

    public static func hostMatchesChildPattern(_ host: String, childPattern: String) -> Bool {
        #if canImport(GetBoredSharedCore)
        return GetBoredSharedCore.DecisionCore().hostMatchesChildPattern(hostOrUrl: host, childPattern: childPattern)
        #else
        let normalizedHost = normalizedHost(host)
        guard let normalizedPattern = normalizeChildPattern(childPattern),
              !normalizedHost.isEmpty,
              !normalizedPattern.isEmpty else {
            return false
        }
        if normalizedPattern.hasPrefix("*.") {
            let suffix = String(normalizedPattern.dropFirst(2))
            return normalizedHost == suffix || normalizedHost.hasSuffix(".\(suffix)")
        }
        return hostMatchesDomain(normalizedHost, domain: normalizedPattern)
        #endif
    }

    public static func hostContainsAnyRelatedKeyword(_ host: String, domains: [String]) -> Bool {
        #if canImport(GetBoredSharedCore)
        return GetBoredSharedCore.DecisionCore().hostContainsAnyRelatedKeyword(
            hostOrUrl: host,
            domainOrUrls: domains
        )
        #else
        let lowered = normalizedHost(host)
        return domains.contains { domain in
            let parts = normalizedHost(domain).split(separator: ".")
            guard parts.count >= 2 else { return false }
            let keyword = String(parts[parts.count - 2])
            guard keyword.count >= 4 else { return false }
            return lowered.contains(keyword)
        }
        #endif
    }

    public static func matchesException(_ url: String, using loadedFilterRules: LoadedFilterRules) -> Bool {
        #if canImport(GetBoredSharedCore)
        return GetBoredSharedCore.DecisionCore().matchesException(
            url: url,
            exceptions: loadedFilterRules.exceptions
        )
        #else
        return matchesIOSExceptionPrefix(url, exceptions: loadedFilterRules.exceptions)
        #endif
    }

    public static func shouldAllowApp(_ sourceApp: String, using loadedFilterRules: LoadedFilterRules) -> Bool {
        #if canImport(GetBoredSharedCore)
        return GetBoredSharedCore.DecisionCore().shouldAllowApp(
            sourceApp: sourceApp,
            policy: kotlinPolicySnapshot(from: loadedFilterRules, systemAllowedSuffixes: [])
        )
        #else
        let appLower = sourceApp.lowercased()
        if appLower.contains(GetBoredIdentifiers.bundlePrefix) {
            return true
        }
        if (appLower.hasSuffix(".com.apple.") || appLower.contains(".com.apple."))
            && !appLower.contains("mobilesafari") {
            return true
        }
        return GetBoredCore.DecisionCore.matchesAllowedApp(sourceApp, using: loadedFilterRules)
        #endif
    }

    public static func shouldLogBlockedAppProbe(_ sourceApp: String?, using loadedFilterRules: LoadedFilterRules) -> Bool {
        #if canImport(GetBoredSharedCore)
        return GetBoredSharedCore.DecisionCore().shouldLogBlockedAppProbe(
            sourceApp: sourceApp,
            policy: kotlinPolicySnapshot(from: loadedFilterRules, systemAllowedSuffixes: [])
        )
        #else
        guard let sourceApp, !sourceApp.isEmpty else { return false }
        return loadedFilterRules.filterMode == .whiteList && !shouldAllowApp(sourceApp, using: loadedFilterRules)
        #endif
    }

    public static func isSystemAllowed(_ host: String, systemAllowedSuffixes: [String]) -> Bool {
        #if canImport(GetBoredSharedCore)
        return GetBoredSharedCore.DecisionCore().isSystemAllowed(
            host: host,
            systemAllowedSuffixes: systemAllowedSuffixes
        )
        #else
        let host = normalizedHost(host)
        return systemAllowedSuffixes.contains { suffix in
            let normalizedSuffix = normalizedHost(suffix)
            return host == normalizedSuffix || host.hasSuffix(".\(normalizedSuffix)")
        }
        #endif
    }

    public static func directSafariProxyDecision(
        host: String,
        using loadedFilterRules: LoadedFilterRules,
        systemAllowedSuffixes: [String]
    ) -> PolicyDecision {
        #if canImport(GetBoredSharedCore)
        let decision = GetBoredSharedCore.DecisionCore().directSafariProxyDecision(
            host: host,
            policy: kotlinPolicySnapshot(from: loadedFilterRules, systemAllowedSuffixes: systemAllowedSuffixes)
        )
        return PolicyDecision(
            kind: decision.kind == GetBoredSharedCore.PolicyDecisionKind.block ? .block : .allow,
            reason: decision.reason
        )
        #else
        if isSystemAllowed(host, systemAllowedSuffixes: systemAllowedSuffixes) {
            return PolicyDecision(kind: .allow, reason: "System allowed")
        }
        let listed = GetBoredCore.DecisionCore.matchesSiteRule(host, using: loadedFilterRules)
        if loadedFilterRules.filterMode == .whiteList {
            return listed
                ? PolicyDecision(kind: .allow, reason: "In allowed list")
                : PolicyDecision(kind: .block, reason: "Not in allowed list")
        }
        return listed
            ? PolicyDecision(kind: .block, reason: "In blocklist")
            : PolicyDecision(kind: .allow, reason: "Not listed")
        #endif
    }

    public static func parentChildDecision(
        host: String,
        endpoint: String,
        activeParent: String?,
        activeChildren: [String],
        activeContextAge: TimeInterval,
        activeContextMaxAge: TimeInterval
    ) -> ParentChildDecision {
        #if canImport(GetBoredSharedCore)
        let decision = GetBoredSharedCore.DecisionCore().parentChildDecision(
            host: host,
            endpoint: endpoint,
            activeParent: activeParent,
            activeChildren: activeChildren,
            activeContextAgeSeconds: activeContextAge,
            activeContextMaxAgeSeconds: activeContextMaxAge
        )
        return ParentChildDecision(
            kind: parentChildKind(from: decision.kind),
            host: decision.host,
            endpoint: decision.endpoint,
            activeParent: decision.activeParent,
            ageSeconds: decision.ageSeconds,
            childCount: Int(decision.childCount),
            event: decision.event,
            observationDecision: decision.observationDecision,
            shouldAllow: decision.shouldAllow
        )
        #else
        return swiftParentChildDecision(
            host: host,
            endpoint: endpoint,
            activeParent: activeParent,
            activeChildren: activeChildren,
            activeContextAge: activeContextAge,
            activeContextMaxAge: activeContextMaxAge
        )
        #endif
    }

    #if canImport(GetBoredSharedCore)
    private static func kotlinPolicySnapshot(
        from loadedFilterRules: LoadedFilterRules,
        systemAllowedSuffixes: [String]
    ) -> GetBoredSharedCore.PolicySnapshot {
        GetBoredSharedCore.PolicySnapshot(
            siteRules: loadedFilterRules.siteRules.map(\.url),
            filterModeRaw: loadedFilterRules.filterMode.rawValue,
            exceptions: loadedFilterRules.exceptions,
            allowedAppBundleIds: loadedFilterRules.allowedAppBundleIDs,
            ownAppBundlePrefixes: [GetBoredIdentifiers.bundlePrefix],
            systemAllowedSuffixes: systemAllowedSuffixes
        )
    }

    private static func parentChildKind(
        from kind: GetBoredSharedCore.ParentChildDecisionKind
    ) -> ParentChildDecisionKind {
        switch kind {
        case GetBoredSharedCore.ParentChildDecisionKind.noActiveContext:
            return .noActiveContext
        case GetBoredSharedCore.ParentChildDecisionKind.staleActiveContext:
            return .staleActiveContext
        case GetBoredSharedCore.ParentChildDecisionKind.matchActiveParent:
            return .matchActiveParent
        case GetBoredSharedCore.ParentChildDecisionKind.matchActiveChild:
            return .matchActiveChild
        default:
            return .noActiveMatch
        }
    }
    #endif

    private static func swiftParentChildDecision(
        host: String,
        endpoint: String,
        activeParent: String?,
        activeChildren: [String],
        activeContextAge: TimeInterval,
        activeContextMaxAge: TimeInterval
    ) -> ParentChildDecision {
        let host = normalizedHost(host)
        guard let activeParent, !activeParent.isEmpty else {
            return ParentChildDecision(
                kind: .noActiveContext,
                host: host,
                endpoint: endpoint,
                activeParent: "",
                ageSeconds: 0,
                childCount: 0,
                event: "BLOCK_NO_CONTEXT host=\(host) endpoint=\(endpoint)",
                observationDecision: "noActiveContext",
                shouldAllow: false
            )
        }

        let normalizedParent = normalizedHost(activeParent)
        if activeContextAge > activeContextMaxAge {
            return ParentChildDecision(
                kind: .staleActiveContext,
                host: host,
                endpoint: endpoint,
                activeParent: normalizedParent,
                ageSeconds: activeContextAge,
                childCount: activeChildren.count,
                event: "BLOCK_STALE host=\(host) activeParent=\(normalizedParent) age=\(formatAge(activeContextAge))",
                observationDecision: "staleActiveContext",
                shouldAllow: false
            )
        }

        if host == normalizedParent {
            return ParentChildDecision(
                kind: .matchActiveParent,
                host: host,
                endpoint: endpoint,
                activeParent: normalizedParent,
                ageSeconds: activeContextAge,
                childCount: activeChildren.count,
                event: "ALLOW_PARENT host=\(host) parent=\(normalizedParent) age=\(formatAge(activeContextAge))",
                observationDecision: "matchActiveParent",
                shouldAllow: true
            )
        }

        if activeChildren.contains(where: { hostMatchesChildPattern(host, pattern: $0) }) {
            return ParentChildDecision(
                kind: .matchActiveChild,
                host: host,
                endpoint: endpoint,
                activeParent: normalizedParent,
                ageSeconds: activeContextAge,
                childCount: activeChildren.count,
                event: "ALLOW_CHILD host=\(host) parent=\(normalizedParent) age=\(formatAge(activeContextAge))",
                observationDecision: "matchActiveChild",
                shouldAllow: true
            )
        }

        return ParentChildDecision(
            kind: .noActiveMatch,
            host: host,
            endpoint: endpoint,
            activeParent: normalizedParent,
            ageSeconds: activeContextAge,
            childCount: activeChildren.count,
            event: "BLOCK_NO_MATCH host=\(host) activeParent=\(normalizedParent) childCount=\(activeChildren.count) age=\(formatAge(activeContextAge))",
            observationDecision: "noActiveMatch",
            shouldAllow: false
        )
    }

    private static func hostMatchesChildPattern(_ host: String, pattern: String) -> Bool {
        let normalizedPattern = normalizedHost(pattern)
        guard !normalizedPattern.isEmpty else { return false }
        if normalizedPattern.hasPrefix("*.") {
            let suffix = String(normalizedPattern.dropFirst(2))
            return host == suffix || host.hasSuffix(".\(suffix)")
        }
        return host == normalizedPattern || host.hasSuffix(".\(normalizedPattern)")
    }

    private static func normalizedHost(_ input: String) -> String {
        var value = input.lowercased()
        if let range = value.range(of: "://") {
            value = String(value[range.upperBound...])
        }
        if let slash = value.firstIndex(of: "/") {
            value = String(value[..<slash])
        }
        if let colon = value.firstIndex(of: ":") {
            value = String(value[..<colon])
        }
        if let question = value.firstIndex(of: "?") {
            value = String(value[..<question])
        }
        return value
    }

    private static func matchesIOSExceptionPrefix(_ url: String, exceptions: [String]) -> Bool {
        let normalizedURL = normalizedURLPrefix(url)
        return exceptions.contains { exception in
            let pattern = normalizedURLPrefix(exception)
            return !pattern.isEmpty && normalizedURL.hasPrefix(pattern)
        }
    }

    private static func normalizedURLPrefix(_ input: String) -> String {
        var value = input.lowercased()
        if let range = value.range(of: "://") {
            value = String(value[range.upperBound...])
        }
        if value.hasPrefix("www.") {
            value = String(value.dropFirst(4))
        }
        return value
    }

    private static func formatAge(_ value: TimeInterval) -> String {
        String(format: "%.1f", (value * 10).rounded() / 10)
    }
}
