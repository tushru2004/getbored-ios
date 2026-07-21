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

    /// The per-app allow gate. Returns true for the "safe set" — own-app, Apple-system, and
    /// parent-whitelisted apps — that the filter must never drop. Builds a PolicySnapshot
    /// (systemAllowedSuffixes empty: app-level allow does not depend on the system host list)
    /// and delegates the actual matching to Kotlin DecisionCore.shouldAllowApp.
    ///
    /// FlowInspector.handleNewFlow MUST call this and return .allow() BEFORE the isAppBlocked
    /// check below — that ordering is why own-app/system traffic can never be dropped.
    /// See DecisionCore.kt shouldAllowApp for the own-app-prefix / com.apple / allowlist branches.
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

    /// Per-app block check against the admin blocked-apps list. Builds a PolicySnapshot and
    /// delegates to Kotlin DecisionCore.isAppBlocked, which matches the full bundle ID or its
    /// team-ID-prefixed form ("TEAMID.com.tiktok.TikTok" matches stored "com.tiktok.TikTok").
    ///
    /// SAFETY: callers (FlowInspector.handleNewFlow) must evaluate shouldAllowApp() and return
    /// .allow() before reaching this — so a bundle that is both allowed and blocked is allowed,
    /// never dropped. This function only consults blockedAppBundleIds; it has no allow logic.
    public static func isAppBlocked(_ sourceApp: String, using loadedFilterRules: LoadedFilterRules) -> Bool {
        #if canImport(GetBoredSharedCore)
        return GetBoredSharedCore.DecisionCore().isAppBlocked(
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

    public static func extractSNI(from data: Data) -> String? {
        #if canImport(GetBoredSharedCore)
        return GetBoredSharedCore.NetworkPayloadPolicy().extractSni(
            byteValues: kotlinIntList(from: data)
        )
        #else
        kotlinCoreUnavailable()
        #endif
    }

    /// SNI vs HTTP asymmetry: `extractSNI` hands Kotlin the raw first-512 bytes,
    /// but the HTTP extractors ASCII-decode that prefix first (HTTP headers are
    /// ASCII text) and bail with nil when the bytes are not ASCII — non-ASCII
    /// means this isn't a plaintext HTTP request worth parsing. Same shape in
    /// `extractHTTPFullURL` below.
    public static func extractHTTPHost(from data: Data) -> String? {
        guard let ascii = String(data: data.prefix(512), encoding: .ascii) else { return nil }
        #if canImport(GetBoredSharedCore)
        return GetBoredSharedCore.NetworkPayloadPolicy().extractHttpHost(rawAscii: ascii)
        #else
        kotlinCoreUnavailable()
        #endif
    }

    public static func extractHTTPFullURL(from data: Data) -> String? {
        guard let ascii = String(data: data.prefix(512), encoding: .ascii) else { return nil }
        #if canImport(GetBoredSharedCore)
        return GetBoredSharedCore.NetworkPayloadPolicy().extractHttpFullUrl(rawAscii: ascii)
        #else
        kotlinCoreUnavailable()
        #endif
    }

    /// Resolve the human-readable domain for a blocked flow. Swift hands Kotlin the
    /// three raw signals it collected off the `NEFilterFlow` (URL host, socket
    /// endpoint, source app); Kotlin's `BlockedHostResolutionPolicy` runs the
    /// cascade and picks the display domain + resolution source. The Swift caller
    /// (`BlockHandler.resolveBlockedHost`) documents the cascade priority order.
    public static func resolveBlockedHost(
        rawURLHost: String?,
        rawEndpoint: String?,
        sourceApp: String?
    ) -> BlockedHostResolution {
        #if canImport(GetBoredSharedCore)
        let resolution = GetBoredSharedCore.BlockedHostResolutionPolicy().resolve(
            rawUrlHost: rawURLHost,
            rawEndpoint: rawEndpoint,
            sourceApp: sourceApp
        )
        return BlockedHostResolution(
            displayDomain: resolution.displayDomain,
            rawEndpoint: resolution.rawEndpoint,
            resolutionSource: resolution.resolutionSource,
            isResolvableHostname: resolution.isResolvableHostname
        )
        #else
        kotlinCoreUnavailable()
        #endif
    }

    /// The Safari App Proxy relay decision — the one bridging call behind every
    /// outbound Safari flow. Swift assembles the inputs (rule snapshot + the live
    /// active-context window); Kotlin returns BOTH the verdict and a set of
    /// side-effect flags that the Swift caller (`SafariAppProxyProvider.shouldRelayFlow`)
    /// then executes. The flags exist because Swift owns all App-Group storage —
    /// Kotlin decides *whether* to refresh context / save an observation, Swift does it.
    ///
    /// Call flow:
    ///
    ///   SafariAppProxyProvider.shouldRelayFlow(endpoint:)
    ///           │
    ///           ▼
    ///   assemble PolicySnapshot (kotlinPolicySnapshot) + active-context scalars
    ///           │
    ///           ▼
    ///   SafariAppProxyPolicy().relayDecision(...)          ← Kotlin owns the verdict
    ///           │
    ///           └── returns Kotlin decision struct
    ///                   │
    ///                   ▼
    ///           map into Swift SafariRelayDecision (parentChildKind via parentChildKind(from:))
    ///                   │
    ///                   ├── shouldRelay                → caller returns this to iOS (relay vs drop)
    ///                   ├── shouldRefreshActiveContext / refreshEvent → caller re-saves context
    ///                   ├── shouldSaveFlowObservation  → caller persists the observation
    ///                   └── primaryEvent / outcomeEvent → caller appends to the spike event log
    public static func safariRelayDecision(
        endpoint: String,
        using loadedFilterRules: LoadedFilterRules,
        systemAllowedSuffixes: [String],
        activeParent: String?,
        activeChildren: [String],
        activeContextAge: TimeInterval,
        activeContextMaxAge: TimeInterval,
        activeContextRefreshMinAge: TimeInterval
    ) -> SafariRelayDecision {
        #if canImport(GetBoredSharedCore)
        let decision = GetBoredSharedCore.SafariAppProxyPolicy().relayDecision(
            endpoint: endpoint,
            policy: kotlinPolicySnapshot(from: loadedFilterRules, systemAllowedSuffixes: systemAllowedSuffixes),
            activeParent: activeParent,
            activeChildren: activeChildren,
            activeContextAgeSeconds: activeContextAge,
            activeContextMaxAgeSeconds: activeContextMaxAge,
            activeContextRefreshMinAgeSeconds: activeContextRefreshMinAge
        )
        return SafariRelayDecision(
            shouldRelay: decision.shouldRelay,
            host: decision.host,
            primaryEvent: decision.primaryEvent,
            outcomeEvent: decision.outcomeEvent,
            parentChildKind: parentChildKind(from: decision.parentChildKind),
            activeParent: decision.activeParent,
            observationDecision: decision.observationDecision,
            shouldSaveFlowObservation: decision.shouldSaveFlowObservation,
            shouldRefreshActiveContext: decision.shouldRefreshActiveContext,
            refreshEvent: decision.refreshEvent
        )
        #else
        kotlinCoreUnavailable()
        #endif
    }

    // MARK: - Parent-Child Store Policy

    /// Kotlin normalizes + validates the raw page-context fields; a nil return
    /// means "reject, write nothing". Swift only maps the accepted result back to
    /// its own struct. `activePageContextFromLegacyPayloadJSON` and
    /// `normalizedFlowObservation` below follow the identical
    /// normalize → nil-guard → map shape.
    public static func normalizedActivePageContext(
        parentDomain: String?,
        childDomains: [String],
        url: String,
        receivedAtSwiftRefSeconds: Double
    ) -> ActivePageContext? {
        #if canImport(GetBoredSharedCore)
        guard let context = GetBoredSharedCore.ParentChildStorePolicy().normalizedActivePageContext(
            parentDomain: parentDomain,
            childDomains: childDomains,
            url: url,
            receivedAt: receivedAtSwiftRefSeconds
        ) else {
            return nil
        }
        return activePageContext(from: context)
        #else
        kotlinCoreUnavailable()
        #endif
    }

    public static func activePageContextFromLegacyPayloadJSON(
        _ json: String?,
        receivedAtSwiftRefSeconds: Double
    ) -> ActivePageContext? {
        #if canImport(GetBoredSharedCore)
        guard let context = GetBoredSharedCore.ParentChildStorePolicy().activePageContextFromLegacyPayloadJson(
            rawJson: json,
            receivedAt: receivedAtSwiftRefSeconds
        ) else {
            return nil
        }
        return activePageContext(from: context)
        #else
        kotlinCoreUnavailable()
        #endif
    }

    public static func normalizedFlowObservation(
        requestHost: String?,
        parentDomain: String?,
        decision: String,
        endpoint: String,
        observedAtSwiftRefSeconds: Double
    ) -> FlowObservation? {
        #if canImport(GetBoredSharedCore)
        guard let observation = GetBoredSharedCore.ParentChildStorePolicy().normalizedFlowObservation(
            requestHost: requestHost,
            parentDomain: parentDomain,
            decision: decision,
            endpoint: endpoint,
            observedAt: observedAtSwiftRefSeconds
        ) else {
            return nil
        }
        return FlowObservation(
            requestHost: observation.requestHost,
            parentDomain: observation.parentDomain,
            decision: observation.decision,
            endpoint: observation.endpoint,
            observedAt: observation.observedAt
        )
        #else
        kotlinCoreUnavailable()
        #endif
    }

    public static func shouldClearActiveContext(
        activeContextJson: String?,
        clearingParent: String?
    ) -> Bool {
        #if canImport(GetBoredSharedCore)
        return GetBoredSharedCore.ParentChildStorePolicy().shouldClearActiveContext(
            activeContextJson: activeContextJson,
            clearingParent: clearingParent
        )
        #else
        kotlinCoreUnavailable()
        #endif
    }

    public static func allowedSafariParentForChild(
        flowObservationJson: String?,
        activeContextJson: String?,
        parentChildMapJson: String?,
        registryJson: String?,
        requestHost: String,
        maxAgeSeconds: Double,
        nowEpochSeconds: Double,
        using loadedFilterRules: LoadedFilterRules
    ) -> AllowedSafariParentDecision? {
        #if canImport(GetBoredSharedCore)
        guard let decision = GetBoredSharedCore.ParentChildStorePolicy().allowedSafariParentForChild(
            flowObservationJson: flowObservationJson,
            activeContextJson: activeContextJson,
            parentChildMapJson: parentChildMapJson,
            registryJson: registryJson,
            requestHost: requestHost,
            maxAgeSeconds: maxAgeSeconds,
            nowEpochSeconds: nowEpochSeconds,
            siteRules: loadedFilterRules.siteRules.map(\.url)
        ) else {
            return nil
        }
        return AllowedSafariParentDecision(
            shouldAllow: decision.shouldAllow,
            parentDomain: decision.parentDomain,
            requestHost: decision.requestHost,
            age: decision.age,
            event: decision.event
        )
        #else
        kotlinCoreUnavailable()
        #endif
    }

    public static func parentChildAppendEvent(
        existingEvents: [String],
        timestamp: String,
        event: String,
        maxEvents: Int
    ) -> [String] {
        #if canImport(GetBoredSharedCore)
        return GetBoredSharedCore.ParentChildStorePolicy().appendEvent(
            existingEvents: existingEvents,
            timestamp: timestamp,
            event: event,
            maxEvents: Int32(maxEvents)
        )
        #else
        kotlinCoreUnavailable()
        #endif
    }

    public static func parentChildMergedChildren(
        parentChildMapJson: String?,
        activeContextJson: String?,
        registryJson: String?,
        parentDomain: String
    ) -> Set<String> {
        #if canImport(GetBoredSharedCore)
        let result = GetBoredSharedCore.ParentChildStorePolicy().mergedChildren(
            parentChildMapJson: parentChildMapJson,
            activeContextJson: activeContextJson,
            registryJson: registryJson,
            parentDomain: parentDomain
        )
        return result
        #else
        kotlinCoreUnavailable()
        #endif
    }

    public static func parentChildUpdatedRegistryJSON(
        registryJson: String?,
        parentDomain: String,
        childDomains: [String]
    ) -> String? {
        #if canImport(GetBoredSharedCore)
        return GetBoredSharedCore.ParentChildStorePolicy().updatedRegistryJson(
            registryJson: registryJson,
            parentDomain: parentDomain,
            childDomains: childDomains
        )
        #else
        kotlinCoreUnavailable()
        #endif
    }

    public static func isValidParentChildMapJSON(_ json: String) -> Bool {
        #if canImport(GetBoredSharedCore)
        return GetBoredSharedCore.ParentChildStorePolicy().isValidParentChildMapJson(parentChildMapJson: json)
        #else
        kotlinCoreUnavailable()
        #endif
    }

    public static func parentChildLegacyPayload(
        parentDomain: String,
        childDomains: [String],
        url: String,
        receivedAtSwiftRefSeconds: Double
    ) -> [String: Any] {
        #if canImport(GetBoredSharedCore)
        let context = GetBoredSharedCore.ActivePageContext(
            parentDomain: parentDomain,
            childDomains: childDomains,
            url: url,
            receivedAt: receivedAtSwiftRefSeconds
        )
        let probe = GetBoredSharedCore.ParentChildStorePolicy().legacyPayload(context: context)
        return [
            "type": probe.type,
            "url": probe.url,
            "parentDomain": probe.parentDomain,
            "childDomains": probe.childDomains,
            "source": probe.source,
            "receivedAt": probe.receivedAt,
        ]
        #else
        kotlinCoreUnavailable()
        #endif
    }

    // MARK: - Activity Log Policy

    /// Strip team-ID prefix from a sourceAppIdentifier. Delegates to Kotlin ActivityLogPolicy.
    public static func activityLogStripTeamID(_ identifier: String?) -> String? {
        #if canImport(GetBoredSharedCore)
        return GetBoredSharedCore.ActivityLogPolicy().stripTeamID(identifier: identifier)
        #else
        kotlinCoreUnavailable()
        #endif
    }

    /// Prepend newEntries onto existing, then apply per-app fairness cap + total cap.
    /// Delegates to Kotlin ActivityLogPolicy.mergeAndTrimEntries.
    ///
    /// Call flow:
    ///
    ///   caller passes Swift ActivityLogEntry arrays
    ///           │
    ///           ▼
    ///   map existing/newEntries → Kotlin DTOs via kotlinActivityLogEntry(from:)
    ///           │
    ///           ▼
    ///   ActivityLogPolicy().mergeAndTrimEntries(...)  ← Kotlin owns ordering + caps
    ///           │
    ///           └── returns Kotlin DTOs
    ///                   │
    ///                   ▼
    ///           result.compactMap { swiftActivityLogEntry(from: $0) }
    ///                   │
    ///                   ├── round-trips cleanly → keeps entry (id preserved)
    ///                   └── round-trip fails    → entry dropped (nil), no crash
    public static func activityLogMergeAndTrim(
        existing: [GetBoredCore.ActivityLogEntry],
        newEntries: [GetBoredCore.ActivityLogEntry],
        maxTotal: Int = 500,
        maxPerApp: Int = 50
    ) -> [GetBoredCore.ActivityLogEntry] {
        #if canImport(GetBoredSharedCore)
        let kotlinExisting = existing.map { kotlinActivityLogEntry(from: $0) }
        let kotlinNew = newEntries.map { kotlinActivityLogEntry(from: $0) }
        let result = GetBoredSharedCore.ActivityLogPolicy().mergeAndTrimEntries(
            existing: kotlinExisting,
            newEntries: kotlinNew,
            maxTotal: Int32(maxTotal),
            maxPerApp: Int32(maxPerApp)
        )
        return result.compactMap { swiftActivityLogEntry(from: $0) }
        #else
        kotlinCoreUnavailable()
        #endif
    }

    #if canImport(GetBoredSharedCore)
    // MARK: - ActivityLogEntry DTO conversion helpers

    private static func activePageContext(from context: GetBoredSharedCore.ActivePageContext) -> ActivePageContext {
        ActivePageContext(
            parentDomain: context.parentDomain,
            childDomains: context.childDomains,
            url: context.url,
            receivedAt: context.receivedAt
        )
    }

    private static func kotlinActivityLogEntry(from entry: GetBoredCore.ActivityLogEntry) -> GetBoredSharedCore.ActivityLogEntry {
        GetBoredSharedCore.ActivityLogEntry(
            id: entry.id.uuidString,
            displayDomain: entry.displayDomain,
            blocked: entry.blocked,
            reason: entry.reason,
            sourceApp: entry.sourceApp,
            rawEndpoint: entry.rawEndpoint,
            resolutionSource: entry.resolutionSource,
            isResolvableHostname: entry.isResolvableHostname,
            timestamp: entry.timestamp.timeIntervalSinceReferenceDate
        )
    }

    /// Call flow:
    ///
    ///   activityLogMergeAndTrim() compactMaps each Kotlin entry through here
    ///           │
    ///           ▼
    ///   build [String: Any] dict (id, displayDomain, blocked, reason, timestamp, …)
    ///           │
    ///           ├── rawEndpoint present → add to dict
    ///           └── sourceApp present   → add to dict
    ///           │
    ///           ▼
    ///   JSONSerialization.data(withJSONObject:) → JSONDecoder().decode(...)
    ///           │
    ///           ├── both succeed → return decoded entry (Decodable init keeps the
    ///           │                  Kotlin id; memberwise init would mint a fresh UUID)
    ///           └── either throws → return nil (caller's compactMap drops it)
    private static func swiftActivityLogEntry(from entry: GetBoredSharedCore.ActivityLogEntry) -> GetBoredCore.ActivityLogEntry? {
        // Route through JSON so GetBoredCore.ActivityLogEntry.init(from:) preserves
        // the Kotlin-supplied id. Its public memberwise inits always generate a
        // fresh UUID, which would break identity tracking on every round-trip.
        var dict: [String: Any] = [
            "id": entry.id,
            "displayDomain": entry.displayDomain,
            "domain": entry.displayDomain,
            "resolutionSource": entry.resolutionSource,
            "isResolvableHostname": entry.isResolvableHostname,
            "blocked": entry.blocked,
            "reason": entry.reason,
            "timestamp": entry.timestamp,
        ]
        if let rawEndpoint = entry.rawEndpoint { dict["rawEndpoint"] = rawEndpoint }
        if let sourceApp = entry.sourceApp { dict["sourceApp"] = sourceApp }
        guard let data = try? JSONSerialization.data(withJSONObject: dict),
              let decoded = try? JSONDecoder().decode(GetBoredCore.ActivityLogEntry.self, from: data) else {
            // Kotlin supplied an entry we cannot round-trip. Skip rather than crash.
            return nil
        }
        return decoded
    }
    #endif

    #if canImport(GetBoredSharedCore)
    /// The shared Swift→Kotlin policy assembly point. Every decision call
    /// (classifyHost, shouldAllowApp, isAppBlocked, safariRelayDecision, …) funnels
    /// its `LoadedFilterRules` through here to build the Kotlin `PolicySnapshot`.
    ///
    /// Two inputs are supplied HERE rather than by the caller:
    ///   - `ownAppBundlePrefixes`: always `[GetBoredIdentifiers.bundlePrefix]` — this
    ///     is what makes GetBored's own traffic un-droppable in `shouldAllowApp`.
    ///   - `systemAllowedSuffixes`: passed `[]` by the per-app allow/block checks (an
    ///     app verdict does not depend on the system host list) and populated only by
    ///     the host-classification / Safari-relay callers.
    private static func kotlinPolicySnapshot(
        from loadedFilterRules: LoadedFilterRules,
        systemAllowedSuffixes: [String]
    ) -> GetBoredSharedCore.PolicySnapshot {
        GetBoredSharedCore.PolicySnapshot(
            siteRules: loadedFilterRules.siteRules.map(\.url),
            filterModeRaw: loadedFilterRules.filterMode.rawValue,
            exceptions: loadedFilterRules.exceptions,
            allowedAppBundleIds: loadedFilterRules.allowedAppBundleIDs,
            blockedAppBundleIds: loadedFilterRules.blockedAppBundleIDs,
            ownAppBundlePrefixes: [GetBoredIdentifiers.bundlePrefix],
            systemAllowedSuffixes: systemAllowedSuffixes
        )
    }

    private static func policyDecision(
        from decision: GetBoredSharedCore.PolicyDecision
    ) -> PolicyDecision {
        let isBlock = decision.kind == GetBoredSharedCore.PolicyDecisionKind.block
        return PolicyDecision(
            kind: isBlock ? .block : .allow,
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

    private static func kotlinIntList(from data: Data) -> [KotlinInt] {
        data.prefix(512).map { byte in KotlinInt(int: Int32(byte)) }
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
