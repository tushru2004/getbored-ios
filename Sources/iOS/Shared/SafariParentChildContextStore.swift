import Foundation
import GetBoredCore
import OSLog

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
        static let legacyActiveContextClearedDateKey =
            "safari_extension_spike_active_page_context_cleared_at"
        static let legacyParentChildRegistryKey = "safari_extension_spike_parent_child_registry"
        static let legacyFlowLogKey = "safari_app_proxy_spike_flows"
        private static let legacySocketExperimentKey = "debug_aws_socket_experiment_v1"

        // The whitelist transport path no longer uses the old Debug switch.
        // Remove a saved flag left by an earlier device experiment.
        func clearLegacySocketExperimentFlag() {
            guard let defaults else { return }
            defaults.removeObject(forKey: Self.legacySocketExperimentKey)
            defaults.synchronize()
            Self.logger.info("SAFARI_TRANSPORT_MIGRATION legacyExperiment=false")
        }

        static let activeContextDataKey = "safari_parent_child_active_context_v1"
        static let flowObservationDataKey = "safari_parent_child_flow_observation_v1"
        static let flowObservationsDataKey = "safari_parent_child_flow_observations_v2"
        static let flowObservationsMaxCount = 64
        static let parentChildMapKey = GetBoredIdentifiers.SafariParentChild.parentChildMapKey
        private static let eventDateFormatter = ISO8601DateFormatter()
        private static let maxEventLength = 512
        private static let logger = Logger(
            subsystem: GetBoredIdentifiers.Logging.iOS,
            category: "SafariParentChildContextStore"
        )

        // One save at a time, so two CNBC children cannot overwrite each other.
        // Only the App Proxy writes this list.
        private static let flowObservationsQueue = DispatchQueue(
            label: "com.getbored.SafariParentChildContextStore.flowObservations")

        // Saved list of recent matches, for example CNBC -> scdn.cnbc.com.
        private struct FlowObservationsWrapper: Codable {
            let schemaVersion: Int
            let observations: [FlowObservation]
        }

        private let defaults: UserDefaults?
        private let encoder = JSONEncoder()
        private let decoder = JSONDecoder()

        init(defaults: UserDefaults? = UserDefaults(suiteName: Self.appGroupIdentifier)) {
            self.defaults = defaults
        }

        /**
         * Save the page the Safari extension just reported.
         *
         * Example: you opened CNBC. The extension reports:
         *   parent: www.cnbc.com
         *   children: scdn.cnbc.com, img.connatix.com
         *
         *          |
         *          ▼
         *
         *   Can we save this page?
         *
         *          ├── no shared storage  →  stop
         *          ├── parent name is missing  →  stop
         *          |
         *          ▼
         *
         *   Save CNBC as the current page.
         *   Also remember its children so a later request can find them.
         *
         *   Keep an older copy too, so the Safari inspector can still read it.
         */
        func saveActiveContext(
            parentDomain: String, childDomains: [String], url: String, receivedAt: Date
        ) {
            guard let defaults else { return }
            guard
                let normalized = IOSDecisionCore.normalizedActivePageContext(
                    parentDomain: parentDomain,
                    childDomains: childDomains,
                    url: url,
                    receivedAtSwiftRefSeconds: receivedAt.timeIntervalSinceReferenceDate
                )
            else {
                return
            }
            let context = ActivePageContext(
                parentDomain: normalized.parentDomain,
                childDomains: normalized.childDomains,
                url: normalized.url,
                receivedAt: receivedAt
            )

#if DEBUG
            let previousContext = loadActiveContext()
            let registrationChanged = previousContext?.parentDomain != context.parentDomain
                || previousContext?.childDomains != context.childDomains
#endif
            if let data = try? encoder.encode(context) {
                defaults.set(data, forKey: Self.activeContextDataKey)
            }

            let legacyPayload = legacyPayload(for: context)
            if JSONSerialization.isValidJSONObject(legacyPayload),
                let data = try? JSONSerialization.data(
                    withJSONObject: legacyPayload, options: [.prettyPrinted, .sortedKeys]),
                let json = String(data: data, encoding: .utf8)
            {
                defaults.set(json, forKey: Self.legacyLastMessageKey)
                defaults.set(receivedAt, forKey: Self.legacyLastMessageDateKey)
                defaults.set(json, forKey: Self.legacyActiveContextKey)
                defaults.set(receivedAt, forKey: Self.legacyActiveContextDateKey)
            }

            updateRegistry(parentDomain: context.parentDomain, childDomains: context.childDomains)
            defaults.synchronize()
#if DEBUG
            // Log changed lists, not every heartbeat. Small batches avoid truncated phone logs.
            // For AWS, this shows whether d0.m.awsstatic.com was actually registered.
            if registrationChanged {
                let children = Array(context.childDomains.prefix(64))
                let omitted = context.childDomains.count - children.count
                Self.logger.info(
                    "REGISTRATION_SNAPSHOT parent=\(context.parentDomain, privacy: .public) total=\(context.childDomains.count, privacy: .public) omitted=\(omitted, privacy: .public) savedAt=\(receivedAt.timeIntervalSinceReferenceDate, privacy: .public)"
                )
                for start in stride(from: 0, to: children.count, by: 2) {
                    let batch = children[start..<min(start + 2, children.count)].joined(separator: ",")
                    Self.logger.info(
                        "REGISTRATION_HOSTS parent=\(context.parentDomain, privacy: .public) savedAt=\(receivedAt.timeIntervalSinceReferenceDate, privacy: .public) hosts=\(batch, privacy: .public)"
                    )
                }
            }
#endif
        }

        /**
         * Clear the saved page, but only if it is the page that closed.
         *
         * Example: the saved page is www.cnbc.com.
         *
         *          |
         *          ▼
         *
         *   Which page closed?
         *
         *          ├── we cannot tell  →  clear it. Broken data is not kept.
         *          |
         *          ▼
         *
         *          The saved page is www.cnbc.com.
         *
         *   Did CNBC close?
         *
         *          ├── yes  →  clear www.cnbc.com
         *          └── no   →  keep it. Closing Docker must not erase CNBC.
         */
        func clearActiveContext(clearingParent: String?) {
            guard let defaults else { return }

            if !IOSDecisionCore.shouldClearActiveContext(
                activeContextJson: loadActiveContextJSON(),
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

        /**
         * Read the saved parent page, for example www.cnbc.com.
         * If the newer format is missing, fall back to an older saved copy.
         */
        func loadActiveContext() -> ActivePageContext? {
            if let data = defaults?.data(forKey: Self.activeContextDataKey),
                let context = try? decoder.decode(ActivePageContext.self, from: data)
            {
                return context
            }

            let legacyPayloadJSON = defaults?.string(forKey: Self.legacyActiveContextKey)
            let legacyReceivedAt = defaults?.object(forKey: Self.legacyActiveContextDateKey) as? Date
            let legacyReceivedAtSeconds = (legacyReceivedAt ?? Date.distantPast)
                .timeIntervalSinceReferenceDate
            guard
                let context = IOSDecisionCore.activePageContextFromLegacyPayloadJSON(
                    legacyPayloadJSON,
                    receivedAtSwiftRefSeconds: legacyReceivedAtSeconds
                )
            else {
                return nil
            }

            return ActivePageContext(
                parentDomain: context.parentDomain,
                childDomains: context.childDomains,
                url: context.url,
                receivedAt: Date(timeIntervalSinceReferenceDate: context.receivedAt)
            )
        }

        /**
         * Which children does CNBC currently list?
         *
         * Example parent: www.cnbc.com
         *
         *          |
         *          ▼
         *
         *   Does the prepared server list children for CNBC?
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
        func mergedChildren(for parentDomain: String) -> Set<String> {
            return IOSDecisionCore.parentChildMergedChildren(
                parentChildMapJson: loadParentChildMapJson(),
                activeContextJson: loadActiveContextJSON(),
                registryJson: loadRegistryJson(),
                parentDomain: parentDomain
            )
        }

        /**
         * Save a recent CNBC child match without erasing the other one.
         * Only the App Proxy writes this list.
         *
         * Example: img.connatix.com was saved at time 123.
         * Now Safari matches scdn.cnbc.com to CNBC at time 124.
         *
         *          |
         *          ▼
         *
         *   Can we save anything right now?
         *
         *          ├── no shared storage  →  stop
         *          ├── child or parent name is missing  →  stop
         *          |
         *          ▼
         *
         *   Read the saved list.
         *
         *          ├── none, or unreadable  →  start empty
         *          |
         *          ▼ Yes, the list currently has:
         *            img.connatix.com at time 123
         *
         *   If scdn.cnbc.com is already in the list, replace that old match.
         *   Then add the new scdn.cnbc.com match at time 124.
         *
         *   The saved list is now:
         *     img.connatix.com at time 123
         *     scdn.cnbc.com at time 124
         *
         *   If more than 64 matches are saved, keep only the newest 64.
         *   Save the whole list once.
         *
         * Saving scdn.cnbc.com does not erase img.connatix.com.
         * A later filter check can still find either child.
         *
         * {
         *   "schemaVersion": 2,
         *   "observations": [
         *     {
         *       "parentDomain": "www.cnbc.com",
         *       "requestHost": "img.connatix.com",
         *       "decision": "matchActiveChild",
         *       "endpoint": "img.connatix.com:443",
         *       "observedAt": 123
         *     },
         *     {
         *       "parentDomain": "www.cnbc.com",
         *       "requestHost": "scdn.cnbc.com",
         *       "decision": "matchActiveChild",
         *       "endpoint": "scdn.cnbc.com:443",
         *       "observedAt": 124
         *     }
         *   ]
         * }
         */
        func saveFlowObservation(
            requestHost: String, parentDomain: String, decision: String, endpoint: String,
            observedAt: Date
        ) {
            guard let defaults else { return }

            let observedAtSeconds = observedAt.timeIntervalSinceReferenceDate
            guard
                let normalized = IOSDecisionCore.normalizedFlowObservation(
                    requestHost: requestHost,
                    parentDomain: parentDomain,
                    decision: decision,
                    endpoint: endpoint,
                    observedAtSwiftRefSeconds: observedAtSeconds
                )
            else {
                return
            }

            let observation = FlowObservation(
                requestHost: normalized.requestHost,
                parentDomain: normalized.parentDomain,
                decision: normalized.decision,
                endpoint: normalized.endpoint,
                observedAt: Date(timeIntervalSinceReferenceDate: normalized.observedAt)
            )
            Self.flowObservationsQueue.sync {
                let decoder = JSONDecoder()
                let encoder = JSONEncoder()
                var existing: [FlowObservation] = []
                if let data = defaults.data(forKey: Self.flowObservationsDataKey),
                    let wrapper = try? decoder.decode(
                        FlowObservationsWrapper.self, from: data),
                    wrapper.schemaVersion == 2
                {
                    existing = wrapper.observations
                }
                existing.removeAll { $0.requestHost == observation.requestHost }
                existing.append(observation)
                existing.sort { $0.observedAt < $1.observedAt }
                if existing.count > Self.flowObservationsMaxCount {
                    existing = Array(existing.suffix(Self.flowObservationsMaxCount))
                }
                let wrapper = FlowObservationsWrapper(schemaVersion: 2, observations: existing)
                if let data = try? encoder.encode(wrapper) {
                    defaults.set(data, forKey: Self.flowObservationsDataKey)
                    defaults.synchronize()
                    Self.logger.info(
                        "OBSERVATION_SAVED child=\(observation.requestHost, privacy: .public) parent=\(observation.parentDomain, privacy: .public) total=\(existing.count, privacy: .public)"
                    )
                }
            }
        }

#if DEBUG
        /// Start a clean AWS test without deleting the synced policy or filter settings.
        /// Safari must be stopped so a page heartbeat cannot immediately restore the map.
        func resetSafariTestData() {
            guard let defaults else { return }
            let keys = [
                Self.activeContextDataKey,
                Self.legacyActiveContextKey,
                Self.legacyActiveContextDateKey,
                Self.legacyActiveContextClearedDateKey,
                Self.legacyLastMessageKey,
                Self.legacyLastMessageDateKey,
                Self.legacyParentChildRegistryKey,
                Self.flowObservationDataKey,
                Self.flowObservationsDataKey,
                Self.legacyFlowLogKey,
            ]
            Self.flowObservationsQueue.sync {
                for key in keys { defaults.removeObject(forKey: key) }
                defaults.synchronize()
            }
            let remaining = keys.filter { defaults.object(forKey: $0) != nil }.count
            Self.logger.info(
                "REGISTRATION_RESET remainingKeys=\(remaining, privacy: .public) policyPreserved=true"
            )
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                let observed = keys.filter { defaults.object(forKey: $0) != nil }.count
                Self.logger.info("REGISTRATION_RESET remainingKeys=\(observed, privacy: .public) policyPreserved=true check=delayed")
            }
        }

        /**
         * Grafana reports a-us.storyblok.com, then Safari requests that exact host.
         * Use only the current page's fresh registration; no App Proxy is needed.
         *
         *   current registration
         *       │
         *       ├── missing, expired, or child absent → no special permission
         *       └── child present → check that the parent is still approved
         *
         * Another Safari tab can benefit from the same registration. This does not
         * prove which tab caused the request. Earlier registry entries are not used.
         */
        func allowedSafariParentFromRegistration(
            _ requestHost: String,
            using rules: LoadedFilterRules,
            maxAge: TimeInterval,
            now: Date = Date()
        ) -> IOSDecisionCore.AllowedSafariParentDecision? {
            guard rules.filterMode == .whiteList,
                let host = IOSDecisionCore.normalizeHost(requestHost), !host.isEmpty,
                let context = loadActiveContext(),
                let parent = IOSDecisionCore.normalizeHost(context.parentDomain), !parent.isEmpty
            else { return nil }

            let age = now.timeIntervalSince(context.receivedAt)
            guard age >= 0, age <= maxAge else { return nil }

            // A registration for one host does not grant access to its subdomains.
            let children = Set(context.childDomains.compactMap(IOSDecisionCore.normalizeHost))
            guard children.contains(host), host != parent else { return nil }

            // Directly approved hosts do not need a dependency permission or its log.
            guard !IOSDecisionCore.matchesSiteRule(host, using: rules) else { return nil }
            let allowed = IOSDecisionCore.matchesSiteRule(parent, using: rules)
            Self.logger.info(
                "REGISTRATION_USED child=\(host, privacy: .public) parent=\(parent, privacy: .public) allowed=\(allowed, privacy: .public) age=\(age, privacy: .public)"
            )
            return IOSDecisionCore.AllowedSafariParentDecision(
                shouldAllow: allowed, parentDomain: parent, requestHost: host, age: age,
                event: "REGISTRATION_USED child=\(host) parent=\(parent) allowed=\(allowed)"
            )
        }
#endif

        /**
         * Decide whether Safari may load scdn.cnbc.com under the saved CNBC parent.
         * This store gathers the saved data and asks the decision core to decide.
         *
         * Example: scdn.cnbc.com, saved parent www.cnbc.com.
         *
         *          |
         *          ▼
         *
         *   Gather:
         *     the saved recent matches,
         *     the saved parent page,
         *     the server mapping,
         *     the earlier registrations.
         *
         *   Ask the decision core:
         *     may scdn.cnbc.com load under www.cnbc.com?
         *
         *          ├── no match  →  no special permission
         *          └── match     →  allow or reject, as the decision core decides
         *
         * The age limit controls how old a saved match may be.
         */
        func allowedSafariParentForChild(
            _ requestHost: String,
            using loadedFilterRules: LoadedFilterRules,
            maxAge: TimeInterval,
            now: Date = Date()
        ) -> IOSDecisionCore.AllowedSafariParentDecision? {
            let decision = IOSDecisionCore.allowedSafariParentForChild(
                flowObservationJson: loadFlowObservationJson(),
                activeContextJson: loadActiveContextJSON(),
                parentChildMapJson: loadParentChildMapJson(),
                registryJson: loadRegistryJson(),
                requestHost: requestHost,
                maxAgeSeconds: maxAge,
                nowEpochSeconds: now.timeIntervalSinceReferenceDate,
                using: loadedFilterRules
            )
            if let decision {
                Self.logger.info(
                    "OBSERVATION_USED child=\(decision.requestHost, privacy: .public) parent=\(decision.parentDomain, privacy: .public) allowed=\(decision.shouldAllow, privacy: .public) age=\(decision.age, privacy: .public)"
                )
            }
            return decision
        }

        /**
         * Add one line to the inspector's log.
         *
         * Example: "ALLOW_CHILD scdn.cnbc.com parent=www.cnbc.com".
         * Keep only the newest 50 lines.
         */
        func appendEvent(_ event: String, maxEvents: Int = 50, now: Date = Date()) {
            guard let defaults else { return }
            let timestamp = Self.eventDateFormatter.string(from: now)
            let events = IOSDecisionCore.parentChildAppendEvent(
                existingEvents: defaults.stringArray(forKey: Self.legacyFlowLogKey) ?? [],
                timestamp: timestamp,
                event: String(event.prefix(Self.maxEventLength)),
                maxEvents: maxEvents
            )
            defaults.set(events, forKey: Self.legacyFlowLogKey)
        }

        /// Read the saved recent matches, for example scdn.cnbc.com and img.connatix.com.
        private func loadFlowObservationJson() -> String? {
            guard let data = defaults?.data(forKey: Self.flowObservationsDataKey) else { return nil }
            return String(data: data, encoding: .utf8)
        }

        /**
         * Read the saved parent page as text the decision core can use.
         *
         * Example: www.cnbc.com, with children scdn.cnbc.com and img.connatix.com.
         * If the newer saved copy is missing, convert the older copy into the same shape.
         */
        private func loadActiveContextJSON() -> String? {
            if let data = defaults?.data(forKey: Self.activeContextDataKey) {
                return String(data: data, encoding: .utf8)
            }

            // Older copies used a different shape. Convert them so the decision core can still read CNBC.
            guard let context = loadActiveContext(),
                let data = try? encoder.encode(context)
            else {
                return nil
            }
            return String(data: data, encoding: .utf8)
        }

        /// Read the prepared server mapping, for example CNBC -> scdn.cnbc.com.
        private func loadParentChildMapJson() -> String? {
            if let data = defaults?.data(forKey: Self.parentChildMapKey) {
                return String(data: data, encoding: .utf8)
            }
            return defaults?.string(forKey: Self.parentChildMapKey)
        }

        /**
         * Read the remembered children for each parent, for example:
         *   www.cnbc.com lists scdn.cnbc.com and img.connatix.com.
         *
         * Older app versions saved this list in different shapes.
         * Try the current text copy first, then older copies, and convert them
         * into the same text so the decision core can still read CNBC's children.
         */
        private func loadRegistryJson() -> String? {
            if let json = defaults?.string(forKey: Self.legacyParentChildRegistryKey) {
                return json
            }
            if let data = defaults?.data(forKey: Self.legacyParentChildRegistryKey) {
                return String(data: data, encoding: .utf8)
            }
            guard let rawRegistry = defaults?.dictionary(forKey: Self.legacyParentChildRegistryKey)
            else {
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

        /**
         * Remember a new CNBC child without forgetting the old ones.
         *
         * Example: CNBC already has scdn.cnbc.com.
         * The extension now also reports img.connatix.com.
         * Keep both.
         */
        private func updateRegistry(parentDomain: String, childDomains: [String]) {
            guard let defaults else { return }
            let updated = IOSDecisionCore.parentChildUpdatedRegistryJSON(
                registryJson: loadRegistryJson(),
                parentDomain: parentDomain,
                childDomains: childDomains
            )
            defaults.set(updated, forKey: Self.legacyParentChildRegistryKey)
        }

        /// Older inspector copy of the saved page, for example www.cnbc.com.
        private func legacyPayload(for context: ActivePageContext) -> [String: Any] {
            IOSDecisionCore.parentChildLegacyPayload(
                parentDomain: context.parentDomain,
                childDomains: context.childDomains,
                url: context.url,
                receivedAtSwiftRefSeconds: context.receivedAt.timeIntervalSinceReferenceDate
            )
        }
    }
