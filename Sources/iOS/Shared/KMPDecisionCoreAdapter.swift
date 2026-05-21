import Foundation
import GetBoredCore

#if canImport(GetBoredSharedCore)
import GetBoredSharedCore
#endif

/// Adapter seam for Kotlin-owned decision logic.
///
/// Swift owns platform collection and type conversion. The Kotlin
/// `GetBoredSharedCore` framework owns policy, normalization, status mapping,
/// and parent-child decisions. When the framework is not importable, this file
/// still compiles for SwiftPM contract tests, but business calls fail fast
/// instead of carrying a second Swift implementation.
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

    public struct FilterStatusViewModel {
        public let filterState: String
        public let filterLabel: String
        public let icloudState: String
        public let icloudLabel: String

        public func toDictionary() -> [String: String] {
            [
                "filterState": filterState,
                "filterLabel": filterLabel,
                "icloudState": icloudState,
                "icloudLabel": icloudLabel,
            ]
        }
    }

    public static func filterStatusViewModel(
        filterEnabled: Bool?,
        filterErrorMessage: String?,
        icloudAvailable: Bool?,
        icloudErrorMessage: String?
    ) -> FilterStatusViewModel {
        #if canImport(GetBoredSharedCore)
        let vm = GetBoredSharedCore.FilterStatusCore().viewModel(
            filterEnabled: filterEnabled.map { KotlinBoolean(bool: $0) },
            filterErrorMessage: filterErrorMessage,
            icloudAvailable: icloudAvailable.map { KotlinBoolean(bool: $0) },
            icloudErrorMessage: icloudErrorMessage
        )
        return FilterStatusViewModel(
            filterState: vm.filterState,
            filterLabel: vm.filterLabel,
            icloudState: vm.icloudState,
            icloudLabel: vm.icloudLabel
        )
        #else
        kotlinCoreUnavailable()
        #endif
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
        kotlinCoreUnavailable()
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
        return policyDecision(from: decision)
        #else
        kotlinCoreUnavailable()
        #endif
    }

    public static func matchesAllowedApp(_ bundleID: String, using loadedFilterRules: LoadedFilterRules) -> Bool {
        #if canImport(GetBoredSharedCore)
        return GetBoredSharedCore.DecisionCore().matchesAllowedApp(
            bundleId: bundleID,
            allowedAppBundleIds: loadedFilterRules.allowedAppBundleIDs
        )
        #else
        kotlinCoreUnavailable()
        #endif
    }

    public static func matchesAllowedApp(_ bundleID: String, allowedAppBundleIDs: [String]) -> Bool {
        #if canImport(GetBoredSharedCore)
        return GetBoredSharedCore.DecisionCore().matchesAllowedApp(
            bundleId: bundleID,
            allowedAppBundleIds: allowedAppBundleIDs
        )
        #else
        kotlinCoreUnavailable()
        #endif
    }

    public static func matchesSiteRule(_ url: String, using loadedFilterRules: LoadedFilterRules) -> Bool {
        #if canImport(GetBoredSharedCore)
        return GetBoredSharedCore.DecisionCore().matchesSiteRule(
            url: url,
            siteRules: loadedFilterRules.siteRules.map(\.url)
        )
        #else
        kotlinCoreUnavailable()
        #endif
    }

    public static func matchesSiteRule(_ url: String, siteRules: [String]) -> Bool {
        #if canImport(GetBoredSharedCore)
        return GetBoredSharedCore.DecisionCore().matchesSiteRule(
            url: url,
            siteRules: siteRules
        )
        #else
        kotlinCoreUnavailable()
        #endif
    }

    public static func normalizeHost(_ value: String?) -> String? {
        guard let value else { return nil }
        #if canImport(GetBoredSharedCore)
        return GetBoredSharedCore.DecisionCore().normalizeHost(input: value)
        #else
        kotlinCoreUnavailable()
        #endif
    }

    public static func normalizeChildPattern(_ value: String?) -> String? {
        guard let value else { return nil }
        #if canImport(GetBoredSharedCore)
        return GetBoredSharedCore.DecisionCore().normalizeChildPattern(input: value)
        #else
        kotlinCoreUnavailable()
        #endif
    }

    public static func hostMatchesDomain(_ host: String, domain: String) -> Bool {
        #if canImport(GetBoredSharedCore)
        return GetBoredSharedCore.DecisionCore().hostMatchesDomain(hostOrUrl: host, domainOrUrl: domain)
        #else
        kotlinCoreUnavailable()
        #endif
    }

    public static func hostMatchesChildPattern(_ host: String, childPattern: String) -> Bool {
        #if canImport(GetBoredSharedCore)
        return GetBoredSharedCore.DecisionCore().hostMatchesChildPattern(hostOrUrl: host, childPattern: childPattern)
        #else
        kotlinCoreUnavailable()
        #endif
    }

    public static func baseKeyword(_ domainOrUrl: String) -> String {
        #if canImport(GetBoredSharedCore)
        return GetBoredSharedCore.DecisionCore().baseKeyword(domainOrUrl: domainOrUrl)
        #else
        kotlinCoreUnavailable()
        #endif
    }

    public static func hostContainsAnyRelatedKeyword(_ host: String, domains: [String]) -> Bool {
        #if canImport(GetBoredSharedCore)
        return GetBoredSharedCore.DecisionCore().hostContainsAnyRelatedKeyword(
            hostOrUrl: host,
            domainOrUrls: domains
        )
        #else
        kotlinCoreUnavailable()
        #endif
    }

    public static func matchesException(_ url: String, using loadedFilterRules: LoadedFilterRules) -> Bool {
        #if canImport(GetBoredSharedCore)
        return GetBoredSharedCore.DecisionCore().matchesException(
            url: url,
            exceptions: loadedFilterRules.exceptions
        )
        #else
        kotlinCoreUnavailable()
        #endif
    }

    public static func matchesException(_ url: String, exceptions: [String]) -> Bool {
        #if canImport(GetBoredSharedCore)
        return GetBoredSharedCore.DecisionCore().matchesException(
            url: url,
            exceptions: exceptions
        )
        #else
        kotlinCoreUnavailable()
        #endif
    }

    public static func shouldAllowApp(_ sourceApp: String, using loadedFilterRules: LoadedFilterRules) -> Bool {
        #if canImport(GetBoredSharedCore)
        return GetBoredSharedCore.DecisionCore().shouldAllowApp(
            sourceApp: sourceApp,
            policy: kotlinPolicySnapshot(from: loadedFilterRules, systemAllowedSuffixes: [])
        )
        #else
        kotlinCoreUnavailable()
        #endif
    }

    public static func shouldLogBlockedAppProbe(_ sourceApp: String?, using loadedFilterRules: LoadedFilterRules) -> Bool {
        #if canImport(GetBoredSharedCore)
        return GetBoredSharedCore.DecisionCore().shouldLogBlockedAppProbe(
            sourceApp: sourceApp,
            policy: kotlinPolicySnapshot(from: loadedFilterRules, systemAllowedSuffixes: [])
        )
        #else
        kotlinCoreUnavailable()
        #endif
    }

    public static func isSystemAllowed(_ host: String, systemAllowedSuffixes: [String]) -> Bool {
        #if canImport(GetBoredSharedCore)
        return GetBoredSharedCore.DecisionCore().isSystemAllowed(
            host: host,
            systemAllowedSuffixes: systemAllowedSuffixes
        )
        #else
        kotlinCoreUnavailable()
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
        return policyDecision(from: decision)
        #else
        kotlinCoreUnavailable()
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
        kotlinCoreUnavailable()
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

    private static func policyDecision(
        from decision: GetBoredSharedCore.PolicyDecision
    ) -> PolicyDecision {
        PolicyDecision(
            kind: decision.kind == GetBoredSharedCore.PolicyDecisionKind.block ? .block : .allow,
            reason: decision.reason
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

    private static func kotlinCoreUnavailable(
        file: StaticString = #fileID,
        line: UInt = #line
    ) -> Never {
        preconditionFailure(
            "GetBoredSharedCore is required for iOS business logic. Run `make kmp` before building app or extension targets.",
            file: file,
            line: line
        )
    }
}
