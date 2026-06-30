import Foundation
import GetBoredCore

struct SafariParentChildContextStore {
    struct ActivePageContext: Codable, Equatable {
        let parentDomain: String
        let childDomains: [String]
        let url: String
        let receivedAt: Date
    }

    struct FlowObservation: Codable, Equatable {
        let requestHost: String
        let parentDomain: String
        let decision: String
        let endpoint: String
        let observedAt: Date
    }

    static let appGroupIdentifier = GetBoredIdentifiers.AppGroup.ios

    static let legacyLastMessageKey = "safari_extension_spike_last_message"
    static let legacyLastMessageDateKey = "safari_extension_spike_last_message_at"
    static let legacyActiveContextKey = "safari_extension_spike_active_page_context"
    static let legacyActiveContextDateKey = "safari_extension_spike_active_page_context_at"
    static let legacyActiveContextClearedDateKey = "safari_extension_spike_active_page_context_cleared_at"
    static let legacyParentChildRegistryKey = "safari_extension_spike_parent_child_registry"
    static let legacyFlowLogKey = "safari_app_proxy_spike_flows"

    static let activeContextDataKey = "safari_parent_child_active_context_v1"
    static let flowObservationDataKey = "safari_parent_child_flow_observation_v1"
    static let parentChildMapKey = GetBoredIdentifiers.SafariParentChild.parentChildMapKey
    private static let eventDateFormatter = ISO8601DateFormatter()
    private static let maxEventLength = 512

    private let defaults: UserDefaults?
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(defaults: UserDefaults? = UserDefaults(suiteName: Self.appGroupIdentifier)) {
        self.defaults = defaults
    }

    /// Call flow:
    ///
    ///   Safari extension sends page context → saveActiveContext(...)
    ///           │
    ///           ▼
    ///       KMPDecisionCoreAdapter.normalizedActivePageContext(...)
    ///           │
    ///           ├── returns nil → return (invalid/empty context, nothing written)
    ///           │
    ///           └── returns normalized context
    ///                   │
    ///                   ├── encode ActivePageContext → defaults[activeContextDataKey]  (v1, typed)
    ///                   │
    ///                   ├── build legacyPayload → defaults[legacyLastMessageKey]       (debug shape)
    ///                   │                      → defaults[legacyActiveContextKey]      (compat read)
    ///                   │                      → defaults[legacyLastMessageDateKey]
    ///                   │                      → defaults[legacyActiveContextDateKey]
    ///                   │
    ///                   ├── updateRegistry(parentDomain:childDomains:)  ← appends to persistent map
    ///                   │
    ///                   └── defaults.synchronize()
    ///
    /// Dual-write (v1 key + legacy keys) keeps the AppProxy and older readers working
    /// during the rollout period before all targets read from activeContextDataKey.
    func saveActiveContext(parentDomain: String, childDomains: [String], url: String, receivedAt: Date) {
        guard let defaults else { return }
        guard let normalized = KMPDecisionCoreAdapter.normalizedActivePageContext(
            parentDomain: parentDomain,
            childDomains: childDomains,
            url: url,
            receivedAtSwiftRefSeconds: receivedAt.timeIntervalSinceReferenceDate
        ) else {
            return
        }
        let context = ActivePageContext(
            parentDomain: normalized.parentDomain,
            childDomains: normalized.childDomains,
            url: normalized.url,
            receivedAt: receivedAt
        )

        if let data = try? encoder.encode(context) {
            defaults.set(data, forKey: Self.activeContextDataKey)
        }

        let legacyPayload = legacyPayload(for: context)
        if JSONSerialization.isValidJSONObject(legacyPayload),
           let data = try? JSONSerialization.data(withJSONObject: legacyPayload, options: [.prettyPrinted, .sortedKeys]),
           let json = String(data: data, encoding: .utf8) {
            defaults.set(json, forKey: Self.legacyLastMessageKey)
            defaults.set(receivedAt, forKey: Self.legacyLastMessageDateKey)
            defaults.set(json, forKey: Self.legacyActiveContextKey)
            defaults.set(receivedAt, forKey: Self.legacyActiveContextDateKey)
        }

        updateRegistry(parentDomain: context.parentDomain, childDomains: context.childDomains)
        defaults.synchronize()
    }

    /// Removes the active page context, but only when the clearing request
    /// actually owns it. The Safari extension fires a "cleared" probe whenever a
    /// tab unloads; without the parent gate a background tab could wipe context
    /// that a still-active foreground tab depends on.
    ///
    /// Call flow:
    ///
    ///   storeProbe (clear message) → clearActiveContext(clearingParent:)
    ///           │
    ///           ├── defaults nil → return  (no App Group)
    ///           │
    ///           ▼
    ///       KMPDecisionCoreAdapter.shouldClearActiveContext(activeContextJson:clearingParent:)
    ///           │
    ///           ├── false → return  (clearingParent doesn't match stored parent → keep context)
    ///           │
    ///           └── true → wipe context:
    ///                   ├── remove activeContextDataKey        ← v1 typed
    ///                   ├── remove legacyActiveContextKey       ← compat read
    ///                   ├── remove legacyActiveContextDateKey
    ///                   ├── set legacyActiveContextClearedDateKey = now  ← audit marker for inspector
    ///                   └── defaults.synchronize()
    func clearActiveContext(clearingParent: String?) {
        guard let defaults else { return }

        if !KMPDecisionCoreAdapter.shouldClearActiveContext(
            activeContextJson: loadActiveContextJSONForKotlin(),
            clearingParent: clearingParent
        ) {
            return
        }

        defaults.removeObject(forKey: Self.activeContextDataKey)
        defaults.removeObject(forKey: Self.legacyActiveContextKey)
        defaults.removeObject(forKey: Self.legacyActiveContextDateKey)
        defaults.set(Date(), forKey: Self.legacyActiveContextClearedDateKey)
        defaults.synchronize()
    }

    /// Call flow:
    ///
    ///   caller calls loadActiveContext()
    ///           │
    ///           ├── v1 key present (activeContextDataKey) → decode → return ActivePageContext
    ///           │
    ///           └── v1 key absent → legacy fallback:
    ///                   │
    ///                   ▼
    ///               KMPDecisionCoreAdapter.activePageContextFromLegacyPayloadJSON(
    ///                   legacyActiveContextKey,       ← debug-shape JSON string
    ///                   legacyActiveContextDateKey    ← stored Date object
    ///               )
    ///                   │
    ///                   ├── Kotlin returns nil → return nil
    ///                   └── Kotlin returns context → wrap in ActivePageContext, return
    ///
    /// The legacy path exists because older app installs wrote the context as a debug
    /// payload dict; the v1 path is the typed Codable encoding introduced later.
    func loadActiveContext() -> ActivePageContext? {
        if let data = defaults?.data(forKey: Self.activeContextDataKey),
           let context = try? decoder.decode(ActivePageContext.self, from: data) {
            return context
        }

        guard let context = KMPDecisionCoreAdapter.activePageContextFromLegacyPayloadJSON(
            defaults?.string(forKey: Self.legacyActiveContextKey),
            receivedAtSwiftRefSeconds: (defaults?.object(forKey: Self.legacyActiveContextDateKey) as? Date ?? Date.distantPast).timeIntervalSinceReferenceDate
        ) else {
            return nil
        }

        return ActivePageContext(
            parentDomain: context.parentDomain,
            childDomains: context.childDomains,
            url: context.url,
            receivedAt: Date(timeIntervalSinceReferenceDate: context.receivedAt)
        )
    }

    /// Unions the child domains for `parentDomain` across all three storage
    /// sources so a child registered by any path is honored. Pure delegation —
    /// Swift only gathers the JSON; Kotlin owns the merge.
    ///
    /// Call flow:
    ///
    ///   shouldRelayFlow → mergedChildren(for:)
    ///           │
    ///           ├── loadParentChildMapJson()         ← server-pushed static map
    ///           ├── loadActiveContextJSONForKotlin() ← current page's childDomains
    ///           ├── loadRegistryJson()               ← accumulated runtime registry
    ///           │
    ///           ▼
    ///       KMPDecisionCoreAdapter.parentChildMergedChildren(...) → Set<String>
    func mergedChildren(for parentDomain: String) -> Set<String> {
        return KMPDecisionCoreAdapter.parentChildMergedChildren(
            parentChildMapJson: loadParentChildMapJson(),
            activeContextJson: loadActiveContextJSONForKotlin(),
            registryJson: loadRegistryJson(),
            parentDomain: parentDomain
        )
    }

    /// Persists the most recent parent↔child flow decision so later
    /// `allowedSafariParentForChild` lookups can reason about what was just
    /// observed. Single-slot (not a log) — each save overwrites the previous.
    ///
    /// Call flow:
    ///
    ///   shouldRelayFlow (decision.shouldSaveFlowObservation) → saveFlowObservation(...)
    ///           │
    ///           ├── defaults nil → return
    ///           │
    ///           ├── KMPDecisionCoreAdapter.normalizedFlowObservation(...) == nil → return  (invalid input dropped)
    ///           │
    ///           └── normalized → encode FlowObservation
    ///                   ├── encode fails → return  (no write)
    ///                   └── encode ok → defaults[flowObservationDataKey] = data → synchronize()
    func saveFlowObservation(requestHost: String, parentDomain: String, decision: String, endpoint: String, observedAt: Date) {
        guard let defaults,
              let normalized = KMPDecisionCoreAdapter.normalizedFlowObservation(
                requestHost: requestHost,
                parentDomain: parentDomain,
                decision: decision,
                endpoint: endpoint,
                observedAtSwiftRefSeconds: observedAt.timeIntervalSinceReferenceDate
              ) else {
            return
        }

        let observation = FlowObservation(
            requestHost: normalized.requestHost,
            parentDomain: normalized.parentDomain,
            decision: normalized.decision,
            endpoint: normalized.endpoint,
            observedAt: Date(timeIntervalSinceReferenceDate: normalized.observedAt)
        )
        if let data = try? encoder.encode(observation) {
            defaults.set(data, forKey: Self.flowObservationDataKey)
            defaults.synchronize()
        }
    }

    /// The central gating function for Safari child-domain allow decisions.
    ///
    /// Call flow:
    ///
    ///   AppProxy or FlowInspector calls allowedSafariParentForChild(requestHost:...)
    ///           │
    ///           ├── loadFlowObservationJson()     → last observed parent↔child flow
    ///           ├── loadActiveContextJSONForKotlin() → current page context (v1 or legacy re-encoded)
    ///           ├── loadParentChildMapJson()       → server-pushed static map
    ///           └── loadRegistryJson()             → accumulated runtime registry
    ///                   │
    ///                   ▼
    ///               KMPDecisionCoreAdapter.allowedSafariParentForChild(
    ///                   ...,
    ///                   requestHost: requestHost,
    ///                   maxAgeSeconds: maxAge,      ← caller controls staleness window
    ///                   nowEpochSeconds: now,
    ///                   using: loadedFilterRules
    ///               )
    ///                   │
    ///                   ├── nil  → no parent found / context too old → block or pass through
    ///                   └── AllowedSafariParentDecision → caller allows the request
    ///
    /// `maxAge` is the staleness window: if the active context is older than maxAge seconds
    /// the Kotlin layer returns nil, preventing stale context from allowing unrelated requests.
    func allowedSafariParentForChild(
        _ requestHost: String,
        using loadedFilterRules: LoadedFilterRules,
        maxAge: TimeInterval,
        now: Date = Date()
    ) -> KMPDecisionCoreAdapter.AllowedSafariParentDecision? {
        KMPDecisionCoreAdapter.allowedSafariParentForChild(
            flowObservationJson: loadFlowObservationJson(),
            activeContextJson: loadActiveContextJSONForKotlin(),
            parentChildMapJson: loadParentChildMapJson(),
            registryJson: loadRegistryJson(),
            requestHost: requestHost,
            maxAgeSeconds: maxAge,
            nowEpochSeconds: now.timeIntervalSinceReferenceDate,
            using: loadedFilterRules
        )
    }

    /// Appends one timestamped line to the spike event ring buffer that the host
    /// app's inspector tail-reads. Kotlin owns the ring-buffer trim so every
    /// target caps the log identically.
    ///
    /// Call flow:
    ///
    ///   appendEvent(event)
    ///           │
    ///           ├── defaults nil → return
    ///           │
    ///           └── KMPDecisionCoreAdapter.parentChildAppendEvent(
    ///                   existingEvents: defaults[legacyFlowLogKey],
    ///                   event: event truncated to maxEventLength (512),  ← bounds UserDefaults growth
    ///                   maxEvents: 50)                                   ← drops oldest beyond cap
    ///                   └── defaults[legacyFlowLogKey] = trimmed events  (no synchronize — best-effort)
    func appendEvent(_ event: String, maxEvents: Int = 50, now: Date = Date()) {
        guard let defaults else { return }
        let timestamp = Self.eventDateFormatter.string(from: now)
        let events = KMPDecisionCoreAdapter.parentChildAppendEvent(
            existingEvents: defaults.stringArray(forKey: Self.legacyFlowLogKey) ?? [],
            timestamp: timestamp,
            event: String(event.prefix(Self.maxEventLength)),
            maxEvents: maxEvents
        )
        defaults.set(events, forKey: Self.legacyFlowLogKey)
    }

    private func loadFlowObservationJson() -> String? {
        guard let data = defaults?.data(forKey: Self.flowObservationDataKey) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Returns the active context as JSON in the shape Kotlin's decoder expects.
    ///
    /// Call flow:
    ///
    ///   v1 key present → decode Data → UTF-8 string (already Codable JSON)
    ///           │
    ///           └── v1 key absent → legacy path:
    ///                   │
    ///                   ▼
    ///               loadActiveContext()   ← triggers the v1→legacy fallback itself
    ///               encoder.encode(context)  ← re-encodes into Codable shape
    ///               return UTF-8 string
    ///
    /// The re-encode step is necessary because the legacy storage format (debug payload dict)
    /// doesn't match the Codable schema Kotlin reads — this function normalizes it.
    private func loadActiveContextJSONForKotlin() -> String? {
        if let data = defaults?.data(forKey: Self.activeContextDataKey) {
            return String(data: data, encoding: .utf8)
        }

        // Legacy storage uses the debug payload shape; Kotlin expects ActivePageContext Codable JSON.
        guard let context = loadActiveContext(),
              let data = try? encoder.encode(context) else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    private func loadParentChildMapJson() -> String? {
        if let data = defaults?.data(forKey: Self.parentChildMapKey) {
            return String(data: data, encoding: .utf8)
        }
        return defaults?.string(forKey: Self.parentChildMapKey)
    }

    /// Three-tier fallback that handles the registry's storage format evolution.
    ///
    ///   Tier 1: stored as String (current write path via updateRegistry)
    ///   Tier 2: stored as Data  (earlier write path that encoded to JSON bytes)
    ///   Tier 3: stored as NSDictionary (oldest path that used UserDefaults native dict)
    ///           → compactMapValues to [String: [String]], then re-serialise to JSON
    ///
    /// All three tiers normalize to the same JSON string for Kotlin.
    private func loadRegistryJson() -> String? {
        if let json = defaults?.string(forKey: Self.legacyParentChildRegistryKey) {
            return json
        }
        if let data = defaults?.data(forKey: Self.legacyParentChildRegistryKey) {
            return String(data: data, encoding: .utf8)
        }
        guard let rawRegistry = defaults?.dictionary(forKey: Self.legacyParentChildRegistryKey) else {
            return nil
        }
        let typed = rawRegistry.compactMapValues { value -> [String]? in
            if let arr = value as? [String] { return arr }
            if let arr = value as? NSArray { return arr.compactMap { $0 as? String } }
            return nil
        }
        guard let data = try? JSONSerialization.data(withJSONObject: typed) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Merge-appends the current page's children into the persistent
    /// parent→children registry — it does NOT overwrite. The registry accumulates
    /// across page loads so a child seen on an earlier visit stays whitelisted.
    ///
    /// Call flow:
    ///
    ///   saveActiveContext → updateRegistry(parentDomain:childDomains:)
    ///           │
    ///           ├── defaults nil → return
    ///           │
    ///           └── KMPDecisionCoreAdapter.parentChildUpdatedRegistryJSON(
    ///                   registryJson: loadRegistryJson(), ...)  ← reads existing, unions children
    ///                   └── defaults[legacyParentChildRegistryKey] = merged JSON
    private func updateRegistry(parentDomain: String, childDomains: [String]) {
        guard let defaults else { return }
        let updated = KMPDecisionCoreAdapter.parentChildUpdatedRegistryJSON(
            registryJson: loadRegistryJson(),
            parentDomain: parentDomain,
            childDomains: childDomains
        )
        defaults.set(updated, forKey: Self.legacyParentChildRegistryKey)
    }

    private func legacyPayload(for context: ActivePageContext) -> [String: Any] {
        KMPDecisionCoreAdapter.parentChildLegacyPayload(
            parentDomain: context.parentDomain,
            childDomains: context.childDomains,
            url: context.url,
            receivedAtSwiftRefSeconds: context.receivedAt.timeIntervalSinceReferenceDate
        )
    }
}
