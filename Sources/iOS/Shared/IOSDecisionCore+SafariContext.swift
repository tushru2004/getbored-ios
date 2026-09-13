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

        /**
         * Clean one saved Safari page.
         *
         * Example: keep www.cnbc.com, plus scdn.cnbc.com and img.connatix.com.
         * Drop empty names and do not list CNBC as its own child.
         */
        public static func normalizedActivePageContext(
            parentDomain: String?, childDomains: [String], url: String,
            receivedAtSwiftRefSeconds: Double
        ) -> ActivePageContext? {
            // Example: keep www.cnbc.com. An empty parent is not a saved page.
            guard let parent = normalizeHost(parentDomain), !parent.isEmpty else { return nil }
            return ActivePageContext(
                parentDomain: parent,
                childDomains: Array(
                    Set(childDomains.compactMap(normalizeHost).filter { !$0.isEmpty && $0 != parent })
                        .sorted()),
                url: url, receivedAt: receivedAtSwiftRefSeconds)
        }
        /**
         * Read an older Safari extension message.
         *
         * Example: parent www.cnbc.com, children scdn.cnbc.com and img.connatix.com.
         * If the parent is missing, ignore the message.
         */
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
        /**
         * Clean one App Proxy observation.
         *
         * Example: child scdn.cnbc.com, parent www.cnbc.com, time 123.
         * If either name is missing, drop it.
         */
        public static func normalizedFlowObservation(
            requestHost: String?, parentDomain: String?, decision: String, endpoint: String,
            observedAtSwiftRefSeconds: Double
        ) -> FlowObservation? {
            // Example: scdn.cnbc.com under www.cnbc.com. Missing either name drops it.
            guard let host = normalizeHost(requestHost), !host.isEmpty,
                let parent = normalizeHost(parentDomain), !parent.isEmpty
            else { return nil }
            return FlowObservation(
                requestHost: host, parentDomain: parent, decision: decision, endpoint: endpoint,
                observedAt: observedAtSwiftRefSeconds)
        }
        /**
         * Should we clear the saved parent after a Safari page is gone?
         *
         * Example: the saved parent is www.cnbc.com.
         *
         *          |
         *          ▼
         *
         *   Can we read the saved parent and the parent we were asked to clear?
         *
         *          ├── no  →  yes, clear it. Broken or missing data is not kept.
         *          |
         *          ▼
         *
         *          Yes: saved parent = www.cnbc.com
         *
         *   Does that saved parent match the page we were asked to clear?
         *
         *          ├── yes  →  clear www.cnbc.com
         *          └── no   →  keep it. A Docker close must not erase CNBC.
         */
        public static func shouldClearActiveContext(activeContextJson: String?, clearingParent: String?)
            -> Bool
        {
            guard let context = decodeContext(activeContextJson),
                let parent = normalizeHost(clearingParent), !parent.isEmpty
            else { return true }
            return context.parentDomain == parent
        }

        /**
         * Decide whether Safari may load scdn.cnbc.com under the saved CNBC parent.
         *
         * Before checking whether it is allowed, we need two pieces of information:
         *   1. Requested child: scdn.cnbc.com, from the network request.
         *   2. Saved parent: www.cnbc.com, from the Safari extension.
         *      When you opened CNBC, the extension saved that parent address.
         *
         *          |
         *          ▼
         *
         *   Can we read the requested child?
         *
         *          ├── no  →  continue normal filtering checks
         *          |
         *          ▼
         *
         *          Yes: scdn.cnbc.com
         *
         *   Can we read the saved parent?
         *
         *          ├── no  →  continue normal filtering checks
         *          |
         *          ▼
         *
         *          Yes: www.cnbc.com
         *
         *   We now have the child and the parent to check.
         *   That is not permission yet.
         *
         *          |
         *          ▼
         *
         *   First moment, App Proxy:
         *     Request: scdn.cnbc.com
         *     Saved parent: www.cnbc.com
         *     Mapping at this time: CNBC includes scdn.cnbc.com
         *     Result: save a recent observation.
         *     Keep both recent children:
         *       scdn.cnbc.com at time 123
         *       img.connatix.com at time 124
         *
         *          |
         *          ▼
         *
         *   Is the saved observation for scdn.cnbc.com still recent?
         *     Skip img.connatix.com: newer, but a different child.
         *
         *          ├── no matching recent observation  →  continue normal filtering checks
         *          |
         *          ▼
         *
         *          Yes
         *
         *   Second moment, content filter:
         *     Read that saved observation.
         *     Check the mapping again: does CNBC currently include scdn.cnbc.com?
         *     This later check only matters if the mapping changed after the first moment.
         *
         *          ├── no  →  continue normal filtering checks
         *          |
         *          ▼
         *
         *          Yes
         *
         *   Do our filter rules allow CNBC?
         *
         *          ├── yes  →  allow scdn.cnbc.com
         *          └── no   →  reject because the parent is not approved
         *
         * Returning no special permission means other filtering checks continue.
         * It does not mean the request is automatically allowed.
         *
         * If these checks pass and our filter rules allow CNBC,
         * then scdn.cnbc.com is also allowed.
         * These checks do not prove that CNBC caused this request.
         * Another Safari tab could open scdn.cnbc.com directly,
         * and it would still be allowed while these checks pass.
         *
         * Saved observations after both children were recorded:
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
         *
         * A later lookup for scdn.cnbc.com uses the first record.
         * Saving img.connatix.com does not hide it.
         */
        public static func allowedSafariParentForChild(
            flowObservationJson: String?, activeContextJson: String?, parentChildMapJson: String?,
            registryJson: String?,
            requestHost: String, maxAgeSeconds: Double, nowEpochSeconds: Double,
            using rules: LoadedFilterRules
        ) -> AllowedSafariParentDecision? {
            // We need the requested child and the saved parent. Example: scdn.cnbc.com
            // and www.cnbc.com. Missing either one means no special permission yet.
            guard let host = normalizeHost(requestHost), !host.isEmpty,
                let context = decodeContext(activeContextJson)
            else { return nil }
            // First moment already saved both children: scdn.cnbc.com at 123 and
            // img.connatix.com at 124. Missing data here is an empty list, not permission.
            let observations = decodeFlowObservations(flowObservationJson)
            let eligible = observations.filter { obs in
                // Keep only a child-match for this exact host and saved parent.
                // Skip img.connatix.com: newer, but a different child.
                guard obs.decision == "matchActiveChild",
                    obs.requestHost == host,
                    obs.parentDomain == context.parentDomain
                else { return false }
                // Example: now 125 minus saved 123 is 2 seconds; a 10-second limit accepts it.
                let age = nowEpochSeconds - obs.observedAt
                return age >= 0 && age <= maxAgeSeconds
            }
            // Use the newest matching observation. img.connatix.com was already excluded.
            guard let observation = eligible.max(by: { $0.observedAt < $1.observedAt }) else {
                return nil
            }
            let age = nowEpochSeconds - observation.observedAt
            // Second moment: check the mapping again. This only matters if it changed
            // after the App Proxy saved the observation.
            guard
                parentChildMergedChildren(
                    parentChildMapJson: parentChildMapJson, activeContextJson: activeContextJson,
                    registryJson: registryJson, parentDomain: observation.parentDomain
                ).contains(where: { hostMatchesChildPattern(host, childPattern: $0) })
            else { return nil }
            // If these checks pass and our rules allow CNBC, allow scdn.cnbc.com too.
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
         * Which children does CNBC currently list?
         *
         * Example parent: www.cnbc.com
         *
         *          |
         *          ▼
         *
         *   Does the prepared server mapping list children for CNBC?
         *
         *          ├── yes  →  use only that server list
         *          |
         *          ▼ No
         *
         *   Combine children saved by the Safari extension:
         *     the current page's children, plus earlier registrations.
         *
         * The server list currently replaces the extension list instead of
         * combining with it. That is a known later concern.
         */
        public static func parentChildMergedChildren(
            parentChildMapJson: String?, activeContextJson: String?, registryJson: String?,
            parentDomain: String
        ) -> Set<String> {
            // Example parent: www.cnbc.com. An empty parent has no children.
            guard let parent = normalizeHost(parentDomain), !parent.isEmpty else { return [] }
            // If the server already lists CNBC children, use that list and stop.
            if let staticChildren = mapChildren(parentChildMapJson, parent: parent),
                !staticChildren.isEmpty
            {
                return staticChildren
            }
            // Otherwise combine the current CNBC page's children with earlier
            // Safari extension registrations for CNBC.
            var result = Set<String>()
            if let context = decodeContext(activeContextJson), context.parentDomain == parent {
                result.formUnion(context.childDomains)
            }
            result.formUnion(registry(registryJson)[parent] ?? [])
            return result
        }
        /**
         * Remember a new CNBC child without forgetting the old ones.
         *
         * Example: CNBC already has scdn.cnbc.com.
         * The extension now also reports img.connatix.com.
         * Keep both.
         */
        public static func parentChildUpdatedRegistryJSON(
            registryJson: String?, parentDomain: String, childDomains: [String]
        ) -> String? {
            // Example parent: www.cnbc.com. An empty parent leaves the old list as-is.
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
        /**
         * Build the older Safari extension message for one parent page.
         * Example: parent www.cnbc.com, children scdn.cnbc.com and img.connatix.com.
         */
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
        /// Read the saved parent, for example www.cnbc.com. Missing data means no saved parent.
        private static func decodeContext(_ json: String?) -> ActivePageContext? {
            guard let json, let data = json.data(using: .utf8),
                let context = try? JSONDecoder().decode(Context.self, from: data)
            else { return nil }
            return ActivePageContext(
                parentDomain: context.parentDomain, childDomains: context.childDomains,
                url: context.url, receivedAt: context.receivedAt)
        }
        /**
         * Read the saved recent observations.
         *
         * Example after CNBC saved two children:
         *   scdn.cnbc.com at time 123
         *   img.connatix.com at time 124
         *
         * If this data is missing or unreadable, return an empty list.
         * An empty list is not permission to allow a child.
         */
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
        /// Read the prepared server mapping. Missing or unreadable data means there is none.
        private static func decodeMap(_ json: String?) -> Map? {
            guard let json, let data = json.data(using: .utf8),
                let map = try? JSONDecoder().decode(Map.self, from: data), map.schemaVersion == 1
            else { return nil }
            return map
        }
        /**
         * Children listed for CNBC in the prepared server mapping.
         * Example: scdn.cnbc.com and img.connatix.com.
         */
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
        /**
         * Children previously registered by the Safari extension.
         * Example: www.cnbc.com lists scdn.cnbc.com and img.connatix.com.
         */
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
