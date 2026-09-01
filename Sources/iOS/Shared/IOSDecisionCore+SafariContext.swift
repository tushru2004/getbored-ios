import Foundation
import GetBoredCore

extension IOSDecisionCore {
        // MARK: - Safari Parent-Child Context Types

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

        // MARK: - Safari Parent-Child Context

        public static func normalizedActivePageContext(
            parentDomain: String?, childDomains: [String], url: String,
            receivedAtSwiftRefSeconds: Double
        ) -> ActivePageContext? {
            guard let parent = normalizeHost(parentDomain), !parent.isEmpty else { return nil }
            return ActivePageContext(
                parentDomain: parent,
                childDomains: Array(
                    Set(childDomains.compactMap(normalizeHost).filter { !$0.isEmpty && $0 != parent })
                        .sorted()),
                url: url, receivedAt: receivedAtSwiftRefSeconds)
        }
        public static func activePageContextFromLegacyPayloadJSON(
            _ json: String?, receivedAtSwiftRefSeconds: Double
        ) -> ActivePageContext? {
            guard let values = jsonObject(json) as? [String: Any],
                let parent = values["parentDomain"] as? String
            else { return nil }
            return normalizedActivePageContext(
                parentDomain: parent, childDomains: values["childDomains"] as? [String] ?? [],
                url: values["url"] as? String ?? "",
                receivedAtSwiftRefSeconds: receivedAtSwiftRefSeconds)
        }
        public static func normalizedFlowObservation(
            requestHost: String?, parentDomain: String?, decision: String, endpoint: String,
            observedAtSwiftRefSeconds: Double
        ) -> FlowObservation? {
            guard let host = normalizeHost(requestHost), !host.isEmpty,
                let parent = normalizeHost(parentDomain), !parent.isEmpty
            else { return nil }
            return FlowObservation(
                requestHost: host, parentDomain: parent, decision: decision, endpoint: endpoint,
                observedAt: observedAtSwiftRefSeconds)
        }
        public static func shouldClearActiveContext(activeContextJson: String?, clearingParent: String?)
            -> Bool
        {
            guard let context = decodeContext(activeContextJson),
                let parent = normalizeHost(clearingParent), !parent.isEmpty
            else { return true }
            return context.parentDomain == parent
        }

        /**
         * Call flow:
         *
         *   request host + saved observation
         *       ├── missing/not a child match → no decision
         *       ▼
         *   validate age + active context + merged children
         *       ├── parent listed → allow child
         *       └── parent not listed → reject child
         */
        public static func allowedSafariParentForChild(
            flowObservationJson: String?, activeContextJson: String?, parentChildMapJson: String?,
            registryJson: String?,
            requestHost: String, maxAgeSeconds: Double, nowEpochSeconds: Double,
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
            let allowed = matchesSiteRule(
                observation.parentDomain, siteRules: rules.siteRules.map(\.url))
            let event: String
            if allowed {
                event =
                    "DATA_PROVIDER_ALLOW_CHILD host=\(host) parent=\(observation.parentDomain) age=\(rounded(age))"
            } else {
                event =
                    "DATA_PROVIDER_REJECT_CHILD_PARENT_NOT_ALLOWLISTED host=\(host) parent=\(observation.parentDomain) age=\(rounded(age))"
            }
            return AllowedSafariParentDecision(
                shouldAllow: allowed, parentDomain: observation.parentDomain, requestHost: host,
                age: age, event: event)
        }
        public static func parentChildAppendEvent(
            existingEvents: [String], timestamp: String, event: String, maxEvents: Int
        ) -> [String] {
            Array((existingEvents + ["\(timestamp) \(event)"]).suffix(max(0, maxEvents)))
        }

        /**
         * Call flow:
         *
         *   normalized parent
         *       ├── static map has children → return static children
         *       └── otherwise → active-context children + learned registry children
         */
        public static func parentChildMergedChildren(
            parentChildMapJson: String?, activeContextJson: String?, registryJson: String?,
            parentDomain: String
        ) -> Set<String> {
            guard let parent = normalizeHost(parentDomain), !parent.isEmpty else { return [] }
            if let staticChildren = mapChildren(parentChildMapJson, parent: parent),
                !staticChildren.isEmpty
            {
                return staticChildren
            }
            var result = Set<String>()
            if let context = decodeContext(activeContextJson), context.parentDomain == parent {
                result.formUnion(context.childDomains)
            }
            result.formUnion(registry(registryJson)[parent] ?? [])
            return result
        }
        public static func parentChildUpdatedRegistryJSON(
            registryJson: String?, parentDomain: String, childDomains: [String]
        ) -> String? {
            guard let parent = normalizeHost(parentDomain), !parent.isEmpty else { return registryJson }
            var entries = registry(registryJson)
            entries[parent, default: []].formUnion(
                childDomains.compactMap(normalizeHost).filter { !$0.isEmpty && $0 != parent })
            let object = entries.mapValues { Array($0).sorted() }
            guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
            else { return registryJson }
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
        private static func rounded(_ value: TimeInterval) -> String {
            String((value * 10).rounded() / 10)
        }
        private static func jsonObject(_ json: String?) -> Any? {
            guard let json, let data = json.data(using: .utf8) else { return nil }
            return try? JSONSerialization.jsonObject(with: data)
        }
        private static func decodeContext(_ json: String?) -> ActivePageContext? {
            guard let json, let data = json.data(using: .utf8),
                let context = try? JSONDecoder().decode(Context.self, from: data)
            else { return nil }
            return ActivePageContext(
                parentDomain: context.parentDomain, childDomains: context.childDomains,
                url: context.url, receivedAt: context.receivedAt)
        }
        private static func decodeObservation(_ json: String?) -> FlowObservation? {
            guard let json, let data = json.data(using: .utf8),
                let observation = try? JSONDecoder().decode(Observation.self, from: data)
            else { return nil }
            return FlowObservation(
                requestHost: observation.requestHost, parentDomain: observation.parentDomain,
                decision: observation.decision, endpoint: observation.endpoint,
                observedAt: observation.observedAt)
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
                guard let parent = normalizeHost(key), !parent.isEmpty, let values = value as? [String]
                else { continue }
                result[parent] = Set(
                    values.compactMap(normalizeHost).filter { !$0.isEmpty && $0 != parent })
            }
            return result
        }
}
