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

    struct ChildAllowMatch: Equatable {
        let parentDomain: String
        let requestHost: String
        let age: TimeInterval
    }

    struct ParentChildMap: Codable, Equatable {
        struct Rule: Codable, Equatable {
            let p: String
            let c: [String]
        }

        struct Wildcard: Codable, Equatable {
            let p: String
            let c: String
        }

        let schemaVersion: Int
        let version: String?
        let publishedAt: String?
        let rules: [Rule]
        let wildcards: [Wildcard]?
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
        let parent = Self.normalizedHost(parentDomain) ?? ""
        guard !parent.isEmpty else { return }

        let children = childDomains
            .compactMap(Self.normalizedHost)
            .filter { !$0.isEmpty && $0 != parent }
        let uniqueChildren = Array(Set(children)).sorted()
        let context = ActivePageContext(
            parentDomain: parent,
            childDomains: uniqueChildren,
            url: url,
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

        updateRegistry(parentDomain: parent, childDomains: uniqueChildren)
        defaults.synchronize()
    }

    func clearActiveContext(clearingParent: String?) {
        guard let defaults else { return }
        let normalizedClearingParent = Self.normalizedHost(clearingParent)

        if let active = loadActiveContext(),
           let normalizedClearingParent,
           active.parentDomain != normalizedClearingParent {
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

        guard let json = defaults?.string(forKey: Self.legacyActiveContextKey),
              let data = json.data(using: .utf8),
              let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let parent = Self.normalizedHost(payload["parentDomain"] as? String),
              !parent.isEmpty else {
            return nil
        }

        let children = (payload["childDomains"] as? [String] ?? [])
            .compactMap(Self.normalizedHost)
            .filter { !$0.isEmpty && $0 != parent }
        let receivedAt = defaults?.object(forKey: Self.legacyActiveContextDateKey) as? Date ?? Date.distantPast
        return ActivePageContext(
            parentDomain: parent,
            childDomains: Array(Set(children)).sorted(),
            url: payload["url"] as? String ?? "",
            receivedAt: receivedAt
        )
    }

    func mergedChildren(for parentDomain: String) -> Set<String> {
        guard let parent = Self.normalizedHost(parentDomain) else { return [] }
        if let staticChildren = parentChildMapChildren(for: parent), !staticChildren.isEmpty {
            return staticChildren
        }

        return dynamicChildren(for: parent)
    }

    func saveParentChildMapJSON(_ json: String) -> Bool {
        guard let defaults,
              let data = json.data(using: .utf8),
              (try? decoder.decode(ParentChildMap.self, from: data)) != nil else {
            return false
        }
        defaults.set(json, forKey: Self.parentChildMapKey)
        defaults.synchronize()
        return true
    }

    func parentChildMapChildren(for parentDomain: String) -> Set<String>? {
        guard let parent = Self.normalizedHost(parentDomain),
              let map = loadParentChildMap() else {
            return nil
        }

        var children = Set<String>()
        for rule in map.rules {
            guard Self.host(parent, matchesDomain: rule.p) else { continue }
            children.formUnion(rule.c.compactMap(Self.normalizedChildPattern).filter { !$0.isEmpty })
        }

        for wildcard in map.wildcards ?? [] {
            guard Self.host(parent, matchesDomain: wildcard.p),
                  let child = Self.normalizedChildPattern(wildcard.c),
                  !child.isEmpty else {
                continue
            }
            children.insert(child)
        }

        return children
    }

    func saveFlowObservation(requestHost: String, parentDomain: String, decision: String, endpoint: String, observedAt: Date) {
        guard let defaults,
              let host = Self.normalizedHost(requestHost),
              let parent = Self.normalizedHost(parentDomain),
              !host.isEmpty,
              !parent.isEmpty else {
            return
        }

        let observation = FlowObservation(
            requestHost: host,
            parentDomain: parent,
            decision: decision,
            endpoint: endpoint,
            observedAt: observedAt
        )
        if let data = try? encoder.encode(observation) {
            defaults.set(data, forKey: Self.flowObservationDataKey)
            defaults.synchronize()
        }
    }

    func freshChildAllowMatch(for requestHost: String, maxAge: TimeInterval, now: Date = Date()) -> ChildAllowMatch? {
        guard let host = Self.normalizedHost(requestHost),
              let observation = loadFlowObservation(),
              observation.decision == "matchActiveChild",
              Self.host(host, matchesDomain: observation.requestHost) else {
            return nil
        }

        let age = now.timeIntervalSince(observation.observedAt)
        guard age >= 0, age <= maxAge else { return nil }

        guard let active = loadActiveContext(),
              active.parentDomain == observation.parentDomain,
              mergedChildren(for: active.parentDomain).contains(where: { Self.host(host, matchesChildPattern: $0) }) else {
            return nil
        }

        return ChildAllowMatch(parentDomain: observation.parentDomain, requestHost: host, age: age)
    }

    func appendEvent(_ event: String, maxEvents: Int = 300, now: Date = Date()) {
        guard let defaults else { return }
        let timestamp = ISO8601DateFormatter().string(from: now)
        var events = defaults.stringArray(forKey: Self.legacyFlowLogKey) ?? []
        events.append("\(timestamp) \(event)")
        defaults.set(Array(events.suffix(maxEvents)), forKey: Self.legacyFlowLogKey)
        defaults.synchronize()
    }

    static func normalizedHost(_ value: String?) -> String? {
        value?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .trimmingCharacters(in: CharacterSet(charactersIn: "."))
    }

    static func host(_ host: String, matchesDomain domain: String) -> Bool {
        guard let normalizedRequestHost = normalizedHost(host),
              let normalizedDomain = normalizedHost(domain),
              !normalizedRequestHost.isEmpty,
              !normalizedDomain.isEmpty else {
            return false
        }
        return normalizedRequestHost == normalizedDomain || normalizedRequestHost.hasSuffix("." + normalizedDomain)
    }

    static func host(_ requestHost: String, matchesChildPattern childPattern: String) -> Bool {
        guard let normalizedRequestHost = normalizedHost(requestHost),
              let normalizedPattern = normalizedChildPattern(childPattern),
              !normalizedRequestHost.isEmpty,
              !normalizedPattern.isEmpty else {
            return false
        }

        if normalizedPattern.hasPrefix("*.") {
            let suffix = String(normalizedPattern.dropFirst(2))
            return normalizedRequestHost == suffix || normalizedRequestHost.hasSuffix("." + suffix)
        }

        return Self.host(normalizedRequestHost, matchesDomain: normalizedPattern)
    }

    private func loadFlowObservation() -> FlowObservation? {
        guard let data = defaults?.data(forKey: Self.flowObservationDataKey) else { return nil }
        return try? decoder.decode(FlowObservation.self, from: data)
    }

    private func loadParentChildMap() -> ParentChildMap? {
        if let data = defaults?.data(forKey: Self.parentChildMapKey) {
            return try? decoder.decode(ParentChildMap.self, from: data)
        }
        if let json = defaults?.string(forKey: Self.parentChildMapKey),
           let data = json.data(using: .utf8) {
            return try? decoder.decode(ParentChildMap.self, from: data)
        }
        return nil
    }

    private func dynamicChildren(for parentDomain: String) -> Set<String> {
        guard let parent = Self.normalizedHost(parentDomain) else { return [] }
        let active = loadActiveContext()
        var children = Set(active?.parentDomain == parent ? active?.childDomains ?? [] : [])
        children.formUnion(registryChildren(for: parent))
        return children
    }

    private func registryChildren(for parentDomain: String) -> Set<String> {
        guard let rawRegistry = defaults?.dictionary(forKey: Self.legacyParentChildRegistryKey),
              let rawChildren = rawRegistry[parentDomain] else {
            return []
        }

        let children: [String]
        if let typedChildren = rawChildren as? [String] {
            children = typedChildren
        } else if let arrayChildren = rawChildren as? NSArray {
            children = arrayChildren.compactMap { $0 as? String }
        } else {
            children = []
        }

        return Set(children
            .compactMap(Self.normalizedHost)
            .filter { !$0.isEmpty && $0 != parentDomain })
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
        [
            "type": "getbored.childRegistrationProbe",
            "url": context.url,
            "parentDomain": context.parentDomain,
            "childDomains": context.childDomains,
            "source": "safari-extension",
            "receivedAt": ISO8601DateFormatter().string(from: context.receivedAt)
        ]
    }

    private static func normalizedChildPattern(_ value: String?) -> String? {
        let trimmed = value?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .trimmingCharacters(in: CharacterSet(charactersIn: "."))
        guard let trimmed, !trimmed.isEmpty else { return nil }
        if trimmed.hasPrefix("*.") {
            let suffix = String(trimmed.dropFirst(2)).trimmingCharacters(in: CharacterSet(charactersIn: "."))
            return suffix.isEmpty ? nil : "*." + suffix
        }
        return trimmed
    }
}
