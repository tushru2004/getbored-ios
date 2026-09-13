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
         * Can the current Safari page load this dependency?
         * Follow one example: CNBC requests scdn.cnbc.com after both hosts below were saved.
         *
         *   Request: scdn.cnbc.com; saved current page: www.cnbc.com
         *       ├── request host or current-page record is unusable → no special allowance
         *       └── both are usable
         *               │
         *               ▼
         *   Read the saved collection (the version-2 JSON example below)
         *       ├── missing, unreadable, or wrong version → no special allowance
         *       └── contains scdn.cnbc.com at time 123 and img.connatix.com at time 124
         *               │
         *               ▼
         *   Look for evidence for this exact host and current parent page
         *       │   scdn.cnbc.com: keep only if its parent is www.cnbc.com,
         *       │     the proxy recorded a child match (matchActiveChild), and it is recent.
         *       │     Example: now 125 - saved 123 = 2 seconds old; limit 10 → recent.
         *       │     A record dated in the future is not accepted either.
         *       │   img.connatix.com: skip; it is newer, but it is a different host.
         *       ├── no record passes these checks → no special allowance
         *       └── a record passes → use it (the newest one if several pass)
         *               │
         *               ▼
         *   Is scdn.cnbc.com still in CNBC's dependency list?
         *       ├── no → no special allowance
         *       └── yes
         *               │
         *               ▼
         *   Does the site's rule list approve www.cnbc.com?
         *       ├── yes → return an allow decision for scdn.cnbc.com
         *       └── no → return a rejection because the parent is not approved
         *
         * "No special allowance" means this function returns nil; the caller continues
         * its other filtering checks. It does not mean the request is automatically allowed.
         * Times 123, 124, and 125 are illustrative; the age limit comes from maxAgeSeconds.
         *
         * Example input after CNBC saves two child observations:
         *
         * ```json
         * {
         *   "schemaVersion": 2,
         *   "observations": [
         *     {
         *       "parentDomain": "www.cnbc.com",
         *       "requestHost": "scdn.cnbc.com",
         *       "decision": "matchActiveChild",
         *       "endpoint": "scdn.cnbc.com:443",
         *       "observedAt": 123
         *     },
         *     {
         *       "parentDomain": "www.cnbc.com",
         *       "requestHost": "img.connatix.com",
         *       "decision": "matchActiveChild",
         *       "endpoint": "img.connatix.com:443",
         *       "observedAt": 124
         *     }
         *   ]
         * }
         * ```
         *
         * A lookup with `requestHost: "scdn.cnbc.com"` selects the first exact-host
         * observation. The newer `img.connatix.com` observation does not hide it.
         *
         * flowObservationJson receives v2 collection JSON (parameter name stays
         * singular for source compatibility).
         */
        public static func allowedSafariParentForChild(
            flowObservationJson: String?, activeContextJson: String?, parentChildMapJson: String?,
            registryJson: String?,
            requestHost: String, maxAgeSeconds: Double, nowEpochSeconds: Double,
            using rules: LoadedFilterRules
        ) -> AllowedSafariParentDecision? {
            // Example: the request is scdn.cnbc.com and the saved current page is www.cnbc.com.
            // Without a usable host and page record, this function cannot grant an allowance.
            guard let host = normalizeHost(requestHost), !host.isEmpty,
                let context = decodeContext(activeContextJson)
            else { return nil }
            // The collection contains both scdn.cnbc.com (time 123) and img.connatix.com (124).
            // Missing or unreadable collection data gives us an empty list, not permission.
            let observations = decodeFlowObservations(flowObservationJson)
            let eligible = observations.filter { obs in
                // For this request, scdn.cnbc.com must belong to the current CNBC page
                // and have been recorded as a child match. Skip img.connatix.com: wrong host.
                guard obs.decision == "matchActiveChild",
                    obs.requestHost == host,
                    obs.parentDomain == context.parentDomain
                else { return false }
                // Example: now 125 - saved 123 = 2 seconds; a 10-second limit accepts it.
                // Reject records that are too old or dated in the future.
                let age = nowEpochSeconds - obs.observedAt
                return age >= 0 && age <= maxAgeSeconds
            }
            // Use the newest record that passed every check, not the newest record overall.
            // Here, scdn.cnbc.com at 123 wins; img.connatix.com at 124 was already excluded.
            guard let observation = eligible.max(by: { $0.observedAt < $1.observedAt }) else {
                return nil
            }
            let age = nowEpochSeconds - observation.observedAt
            // Saved evidence alone is not enough: CNBC's dependency list must still
            // include scdn.cnbc.com. Otherwise, return nil and leave other checks to the caller.
            guard
                parentChildMergedChildren(
                    parentChildMapJson: parentChildMapJson, activeContextJson: activeContextJson,
                    registryJson: registryJson, parentDomain: observation.parentDomain
                ).contains(where: { hostMatchesChildPattern(host, childPattern: $0) })
            else { return nil }
            // Finally, check CNBC itself. If www.cnbc.com matches the site's rule list,
            // return an allow decision for scdn.cnbc.com; otherwise return a rejection.
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
        private struct FlowObservationsWrapper: Codable {
            let schemaVersion: Int
            let observations: [Observation]
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
        private static func decodeFlowObservations(_ json: String?) -> [FlowObservation] {
            guard let json, let data = json.data(using: .utf8),
                let wrapper = try? JSONDecoder().decode(FlowObservationsWrapper.self, from: data),
                wrapper.schemaVersion == 2
            else { return [] }
            return wrapper.observations.map {
                FlowObservation(
                    requestHost: $0.requestHost, parentDomain: $0.parentDomain,
                    decision: $0.decision, endpoint: $0.endpoint, observedAt: $0.observedAt)
            }
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
