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

    private let defaults: UserDefaults?
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(defaults: UserDefaults? = UserDefaults(suiteName: Self.appGroupIdentifier)) {
        self.defaults = defaults
    }

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

    func mergedChildren(for parentDomain: String) -> Set<String> {
        return KMPDecisionCoreAdapter.parentChildMergedChildren(
            parentChildMapJson: loadParentChildMapJson(),
            activeContextJson: loadActiveContextJSONForKotlin(),
            registryJson: loadRegistryJson(),
            parentDomain: parentDomain
        )
    }

    func saveParentChildMapJSON(_ json: String) -> Bool {
        guard let defaults,
              KMPDecisionCoreAdapter.isValidParentChildMapJSON(json) else {
            return false
        }
        defaults.set(json, forKey: Self.parentChildMapKey)
        defaults.synchronize()
        return true
    }

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

    func appendEvent(_ event: String, maxEvents: Int = 300, now: Date = Date()) {
        guard let defaults else { return }
        let timestamp = ISO8601DateFormatter().string(from: now)
        let events = KMPDecisionCoreAdapter.parentChildAppendEvent(
            existingEvents: defaults.stringArray(forKey: Self.legacyFlowLogKey) ?? [],
            timestamp: timestamp,
            event: event,
            maxEvents: maxEvents
        )
        defaults.set(events, forKey: Self.legacyFlowLogKey)
        defaults.synchronize()
    }

    private func loadFlowObservationJson() -> String? {
        guard let data = defaults?.data(forKey: Self.flowObservationDataKey) else { return nil }
        return String(data: data, encoding: .utf8)
    }

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

    private func loadRegistryJson() -> String? {
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

    private func updateRegistry(parentDomain: String, childDomains: [String]) {
        guard let defaults else { return }
        var registry = defaults.dictionary(forKey: Self.legacyParentChildRegistryKey) as? [String: [String]] ?? [:]
        var existing = Set(registry[parentDomain] ?? [])
        existing.formUnion(childDomains)
        registry[parentDomain] = existing.sorted()
        defaults.set(registry, forKey: Self.legacyParentChildRegistryKey)
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
