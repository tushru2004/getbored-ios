/**
 *
 *  IOSRuleStore.swift
 *  GetBored iOS Shared
 *
 *  Created by Tushar on 26.02.26.
 *
 *  Reads/writes the iOS filter rule snapshot via App Group UserDefaults.
 *  Same role as MacRuleStore.swift on macOS, but reads from shared
 *  UserDefaults instead of vendorConfiguration (iOS extensions resolve
 *  the app group container at the same path as the user app).
 *
 */

import Foundation
import GetBoredCore
import OSLog

// MARK: - Downloaded policy schedule

    /// One assigned server list retained locally so schedule boundaries can be
    /// evaluated while the app is not foregrounded. A missing schedule preserves
    /// the pre-schedule contract: the list is active all the time.
    struct IOSAssignedPolicyList: Codable {
        let id: String
        let filterMode: FilterListMode
        let entries: [String]
        let exceptions: [String]
        let allowedApps: [String]
        let blockedApps: [String]
        let schedule: IOSPolicySchedule?

        func isActive(at date: Date) -> Bool {
            schedule?.isActive(at: date) ?? true
        }

        func validate() throws {
            guard !id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw IOSPolicySchedule.ValidationError.emptyListID
            }
            try schedule?.validate()
        }
    }

    /// The v1 weekly schedule wire format. Weekdays use Monday = 1 ... Sunday = 7.
    struct IOSPolicySchedule: Codable {
        enum Mode: String, Codable {
            case always
            case weekly
        }

        struct Interval: Codable {
            let weekday: Int
            let start: String
            let end: String
        }

        enum ValidationError: LocalizedError {
            case unsupportedVersion(Int)
            case invalidTimezone(String)
            case intervalsNotAllowedForAlways
            case invalidWeekday(Int)
            case invalidTime(String)
            case invalidRange(start: String, end: String)
            case overlappingIntervals(weekday: Int)
            case emptyListID
            case duplicateListID(String)

            var errorDescription: String? {
                switch self {
                case .unsupportedVersion(let version): return "Unsupported policy schedule version \(version)."
                case .invalidTimezone(let timezone): return "Invalid policy schedule timezone \(timezone)."
                case .intervalsNotAllowedForAlways: return "Always-active policy schedules cannot contain intervals."
                case .invalidWeekday(let weekday): return "Invalid policy schedule weekday \(weekday)."
                case .invalidTime(let time): return "Invalid policy schedule time \(time)."
                case .invalidRange(let start, let end): return "Invalid policy schedule range \(start)-\(end)."
                case .overlappingIntervals(let weekday): return "Overlapping policy schedule intervals on weekday \(weekday)."
                case .emptyListID: return "Policy list ID cannot be empty."
                case .duplicateListID(let id): return "Duplicate policy list ID \(id)."
                }
            }
        }

        let version: Int
        let mode: Mode
        let timezone: String
        let intervals: [Interval]

        func validate() throws {
            guard version == 1 else { throw ValidationError.unsupportedVersion(version) }
            guard TimeZone(identifier: timezone) != nil else {
                throw ValidationError.invalidTimezone(timezone)
            }
            if mode == .always {
                guard intervals.isEmpty else { throw ValidationError.intervalsNotAllowedForAlways }
                return
            }

            var intervalsByWeekday = [Int: [(start: Int, end: Int)]]()
            for interval in intervals {
                guard (1...7).contains(interval.weekday) else {
                    throw ValidationError.invalidWeekday(interval.weekday)
                }
                let start = try minuteOfDay(interval.start)
                let end = try minuteOfDay(interval.end)
                guard end > start else {
                    throw ValidationError.invalidRange(start: interval.start, end: interval.end)
                }
                intervalsByWeekday[interval.weekday, default: []].append((start, end))
            }

            for (weekday, ranges) in intervalsByWeekday {
                let sorted = ranges.sorted { $0.start < $1.start }
                for (previous, current) in zip(sorted, sorted.dropFirst()) where current.start < previous.end {
                    throw ValidationError.overlappingIntervals(weekday: weekday)
                }
            }
        }

        func isActive(at date: Date) -> Bool {
            guard mode == .weekly, let timeZone = TimeZone(identifier: timezone) else {
                return mode == .always
            }
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = timeZone
            let components = calendar.dateComponents([.weekday, .hour, .minute], from: date)
            guard let weekday = components.weekday, let hour = components.hour, let minute = components.minute else {
                return false
            }
            // Calendar.weekday is Sunday = 1 ... Saturday = 7; the API is ISO-style.
            let apiWeekday = weekday == 1 ? 7 : weekday - 1
            let now = hour * 60 + minute
            return intervals.contains {
                guard $0.weekday == apiWeekday,
                    let start = try? minuteOfDay($0.start), let end = try? minuteOfDay($0.end)
                else { return false }
                return start <= now && now < end
            }
        }

        private func minuteOfDay(_ value: String) throws -> Int {
            let pieces = value.split(separator: ":", omittingEmptySubsequences: false)
            guard pieces.count == 2, pieces[0].count == 2, pieces[1].count == 2,
                pieces.allSatisfy({ $0.allSatisfy(\.isNumber) }),
                let hour = Int(pieces[0]), let minute = Int(pieces[1]),
                (0...23).contains(hour), (0...59).contains(minute)
            else { throw ValidationError.invalidTime(value) }
            return hour * 60 + minute
        }
    }

// MARK: - IOSRuleStore

    /**
     * Shared App Group storage for the iOS filter policy.
     *
     * The app writes the server policy here. The Data and Control Providers read
     * the same snapshot, then `IOSDecisionCore` evaluates it. This store moves
     * data between targets; it does not make allow or block decisions.
     */
    class IOSRuleStore {
        static let shared = IOSRuleStore()
        private let logger = Logger(
            subsystem: GetBoredIdentifiers.Logging.iOS, category: "IOSRuleStore")

        /// App Group identifier — must match the entitlement on all 3 targets
        private let appGroupIdentifier = GetBoredIdentifiers.AppGroup.ios

        // MARK: - UserDefaults Keys

        /// JSON-encoded [SiteRule] — the blocklist/allowlist of domains
        private let siteRulesKey = "site_rules"

        /// JSON-encoded v2 assigned lists, retained so providers can locally
        /// evaluate a future weekly boundary without requiring a fresh pull.
        private let assignedPolicyListsKey = "assigned_policy_lists_v2"

        /// String — "blockSpecific" or "whiteList"
        private let modeKey = "filter_mode"

        /// [String] — URL path exceptions (allowed even if domain is blocked)
        private let exceptionsKey = "filter_exceptions"

        /// [String] — bundle IDs of apps that bypass filtering entirely
        private let allowedAppsKey = "allowedAppBundleIDs"

        /// [String] — bundle IDs of apps whose traffic is blocked entirely
        private let blockedAppsKey = "blockedAppBundleIDs"

        /// JSON-encoded [ActivityLogEntry] — filter decision log
        private let logKey = "activity_log_entries"

        // MARK: - Cached UserDefaults

        /// Cached UserDefaults instance. Re-creating UserDefaults(suiteName:) on every call
        /// is expensive in the filter extension hot path. The cache auto-refreshes every 5 seconds.
        private var _cachedDefaults: UserDefaults?
        private var _defaultsCacheTime: Date = .distantPast
        private let defaultsCacheInterval: TimeInterval = 5.0

        /**
         * Call flow:
         *
         *   caller accesses sharedDefaults
         *           │
         *           ├── cache is valid (age < 5 s) → return _cachedDefaults (no allocation)
         *           │
         *           └── cache is stale or nil
         *                   │
         *                   ▼
         *               UserDefaults(suiteName: appGroupIdentifier)   ← new instance
         *               _defaultsCacheTime = now
         *               return _cachedDefaults
         *
         * The 5-second TTL exists because UserDefaults(suiteName:) is expensive to
         * allocate on every call, yet the filter extension needs cross-process data
         * that another process may have written since the last read.
         */
        private var sharedDefaults: UserDefaults? {
            let now = Date()
            let cacheIsMissing = _cachedDefaults == nil
            let cacheAge = now.timeIntervalSince(_defaultsCacheTime)
            let cacheIsStale = cacheAge > defaultsCacheInterval

            if cacheIsMissing || cacheIsStale {
                _cachedDefaults = UserDefaults(suiteName: appGroupIdentifier)
                _defaultsCacheTime = now
            }
            return _cachedDefaults
        }

        /// Force the next access to re-create the UserDefaults instance,
        /// ensuring completely fresh cross-process data is read.
        func invalidateDefaultsCache() {
            logger.debug("invalidateDefaultsCache: clearing UserDefaults cache")
            _cachedDefaults = nil
            _defaultsCacheTime = .distantPast
        }

        // MARK: - Site Rules (blocklist/allowlist)

        /// Load all site rules from shared UserDefaults
        private func loadStoredSiteRules() -> [SiteRule] {
            guard let data = sharedDefaults?.data(forKey: siteRulesKey),
                let items = try? JSONDecoder().decode([SiteRule].self, from: data)
            else {
                logger.debug("loadSiteRules: no data found or decode failed, returning empty")
                return []
            }
            logger.debug("loadSiteRules: loaded \(items.count, privacy: .public) items")
            return items
        }

        /// Returns the rules effective at this instant, including locally evaluated schedules.
        func loadSiteRules() -> [SiteRule] {
            loadFilterRules().siteRules
        }

        /**
         * Load the full policy snapshot expected by the shared decision core.
         *
         * This is the single chokepoint all consumers (FlowInspector, IOSDecisionCore,
         * isListed/isExcepted/isAppAllowed/isAppBlocked below) go through to get a filter mode.
         * Debug and Release both honor the selected Allow List or Block List mode.
         *
         * Call flow:
         *
         *   filter extension (hot path) calls loadFilterRules()
         *           │
         *           ├── decodedFilterMode()  → same selected mode in Debug and Release
         *           ├── loadSiteRules()     → [SiteRule] from JSON in UserDefaults
         *           ├── loadExceptions()   → [String] from UserDefaults
         *           ├── loadAllowedApps()  → [String] from UserDefaults
         *           └── loadBlockedApps()  → [String] from UserDefaults
         *                   │
         *                   ▼
         *               LoadedFilterRules (passed to IOSDecisionCore for every decision)
         *
         * All five reads hit the same cached UserDefaults instance (5-second TTL).
         */
        func loadFilterRules() -> LoadedFilterRules {
            switch loadAssignedPolicyLists() {
            case .present(let lists):
                return effectiveRules(from: lists, at: Date())

            case .malformed:
                // Do not silently turn a corrupt scheduled snapshot into an
                // unrestricted block list. System and own-app bypasses remain
                // in IOSDecisionCore/FlowInspector, but unlisted traffic stops.
                return LoadedFilterRules(
                    siteRules: [],
                    filterMode: .whiteList,
                    exceptions: [],
                    allowedAppBundleIDs: [],
                    blockedAppBundleIDs: []
                )

            case .absent:
                break
            }
            return LoadedFilterRules(
                siteRules: loadStoredSiteRules(),
                filterMode: decodedFilterMode(),
                exceptions: loadExceptions(),
                allowedAppBundleIDs: loadAllowedApps(),
                blockedAppBundleIDs: loadBlockedApps()
            )
        }

        /// A stable comparison value for consumers that keep per-policy state,
        /// such as Safari's broad resource transport allowance.
        func policyFingerprint(for rules: LoadedFilterRules) -> String {
            ([rules.filterMode.rawValue]
                + rules.siteRules.map(\.url)
                + ["|exceptions|"] + rules.exceptions
                + ["|allowed-apps|"] + rules.allowedAppBundleIDs
                + ["|blocked-apps|"] + rules.blockedAppBundleIDs
            ).joined(separator: "\u{1F}")
        }

        private enum AssignedPolicyListsLoadResult {
            case absent
            case present([IOSAssignedPolicyList])
            case malformed
        }

        private func loadAssignedPolicyLists() -> AssignedPolicyListsLoadResult {
            guard let data = sharedDefaults?.data(forKey: assignedPolicyListsKey) else { return .absent }
            do {
                let lists = try JSONDecoder().decode([IOSAssignedPolicyList].self, from: data)
                var IDs = Set<String>()
                for list in lists {
                    try list.validate()
                    guard IDs.insert(list.id).inserted else {
                        throw IOSPolicySchedule.ValidationError.duplicateListID(list.id)
                    }
                }
                return .present(lists)
            } catch {
                logger.error("loadAssignedPolicyLists: decode failed; retaining fail-closed stored policy")
                return .malformed
            }
        }

        private func effectiveRules(
            from lists: [IOSAssignedPolicyList], at date: Date
        ) -> LoadedFilterRules {
            let activeLists = lists.filter { $0.isActive(at: date) }
            let mode: FilterMode = activeLists.contains { $0.filterMode == .whiteList }
                ? .whiteList : .blockSpecific
            return LoadedFilterRules(
                siteRules: orderedUnique(activeLists.flatMap(\.entries)).map { SiteRule(url: $0, title: $0) },
                filterMode: mode,
                exceptions: orderedUnique(activeLists.flatMap(\.exceptions)),
                allowedAppBundleIDs: orderedUnique(activeLists.flatMap(\.allowedApps)),
                blockedAppBundleIDs: orderedUnique(activeLists.flatMap(\.blockedApps))
            )
        }

        private func orderedUnique(_ values: [String]) -> [String] {
            var seen = Set<String>()
            return values.filter { seen.insert($0).inserted }
        }

        /// Save site rules to shared UserDefaults
        func saveSiteRules(_ items: [SiteRule]) {
            guard let data = try? JSONEncoder().encode(items) else {
                logger.error("saveSiteRules: failed to encode items")
                return
            }
            logger.info("saveSiteRules: saving \(items.count, privacy: .public) items")
            let defaults = sharedDefaults
            defaults?.removeObject(forKey: assignedPolicyListsKey)
            defaults?.set(data, forKey: siteRulesKey)
            defaults?.synchronize()
        }

        /// Check if a host matches any site rule (exact or subdomain match)
        func isListed(url: String) -> Bool {
            IOSDecisionCore.matchesSiteRule(url, using: loadFilterRules())
        }

        /// Returns true if there are any site rules configured
        func hasAnyEntries() -> Bool {
            !loadFilterRules().siteRules.isEmpty
        }

        // MARK: - Filter List Snapshot

        /**
         * Replaces the full filter policy with a server-merged snapshot.
         *
         * `syncFilterLists` fetches the already-merged result from `GET /api/policy`
         * and hands it straight to this writer.
         *
         * Call flow:
         *
         *   syncFilterLists fetches this device's merged policy from GET /api/policy
         *           │
         *           ▼
         *   applyFilterListSnapshot(mode:entries:exceptions:allowedApps:blockedApps:)
         *           │
         *           ├── convert [String] entries → [SiteRule] (url = title = entry)
         *           ├── convert FilterListMode → FilterMode (same raw value)
         *           ├── write siteRulesKey, modeKey, exceptionsKey, allowedAppsKey, blockedAppsKey in one defaults batch
         *           ├── defaults.synchronize()  ← flush cross-process so extension sees new values
         *           └── invalidateDefaultsCache()  ← force next read to re-create UserDefaults instance
         *
         * All five keys are written before `synchronize()` asks the shared defaults
         * store to publish the new snapshot to the extension processes.
         */
        func applyFilterListSnapshot(
            mode: FilterListMode,
            entries: [String],
            exceptions: [String],
            allowedApps: [String],
            blockedApps: [String]
        ) {
            let filterMode = FilterMode(rawValue: mode.rawValue) ?? .blockSpecific
            let siteRules = entries.map { SiteRule(url: $0, title: $0) }
            let defaults = sharedDefaults

            defaults?.removeObject(forKey: assignedPolicyListsKey)
            if let data = try? JSONEncoder().encode(siteRules) {
                defaults?.set(data, forKey: siteRulesKey)
            }
            defaults?.set(filterMode.rawValue, forKey: modeKey)
            defaults?.set(exceptions, forKey: exceptionsKey)
            defaults?.set(allowedApps, forKey: allowedAppsKey)
            defaults?.set(blockedApps, forKey: blockedAppsKey)
            defaults?.synchronize()

            invalidateDefaultsCache()

            logger.info(
                "applyFilterListSnapshot: \(entries.count, privacy: .public) entries, mode=\(filterMode.rawValue, privacy: .public), \(exceptions.count, privacy: .public) exceptions, \(allowedApps.count, privacy: .public) allowedApps, \(blockedApps.count, privacy: .public) blockedApps"
            )
        }

        /// Replaces the v2 assigned-list snapshot atomically. Validation happens
        /// before this method is called, so a malformed download never displaces
        /// the last known good offline policy.
        func applyScheduledPolicyLists(_ lists: [IOSAssignedPolicyList]) {
            guard let data = try? JSONEncoder().encode(lists) else {
                logger.error("applyScheduledPolicyLists: failed to encode lists")
                return
            }
            let defaults = sharedDefaults
            defaults?.set(data, forKey: assignedPolicyListsKey)
            defaults?.synchronize()
            invalidateDefaultsCache()
            logger.info("applyScheduledPolicyLists: stored \(lists.count, privacy: .public) assigned lists")
        }

        // MARK: - Filter Mode

        /// Set the filter mode ("blockSpecific" or "whiteList")
        func setMode(_ mode: String) {
            logger.info("setMode: \(mode, privacy: .public)")
            let defaults = sharedDefaults
            defaults?.removeObject(forKey: assignedPolicyListsKey)
            defaults?.set(mode, forKey: modeKey)
            defaults?.synchronize()
        }

        /// Return the same effective mode used by the filter for the Active Rules screen.
        func getMode() -> String {
            let mode = loadFilterRules().filterMode.rawValue
            logger.debug("getMode: \(mode, privacy: .public)")
            return mode
        }

        /**
         * Preserve the server's selected mode in both Debug and Release.
         * For example, whiteList with docker.com allows Docker rather than blocking it.
         * Missing or unknown stored values fall back to blockSpecific.
         */
        private func decodedFilterMode() -> FilterMode {
            let rawMode = sharedDefaults?.string(forKey: modeKey) ?? FilterMode.blockSpecific.rawValue
            return FilterMode(rawValue: rawMode) ?? .blockSpecific
        }

        // MARK: - Exceptions (URL path exemptions)

        /// Load exception patterns (e.g. "instagram.com/school-account")
        func loadExceptions() -> [String] {
            return sharedDefaults?.stringArray(forKey: exceptionsKey) ?? []
        }

        /// Save exception patterns
        func setExceptions(_ exceptions: [String]) {
            logger.info("setExceptions: \(exceptions.count, privacy: .public) exceptions")
            let defaults = sharedDefaults
            defaults?.removeObject(forKey: assignedPolicyListsKey)
            defaults?.set(exceptions, forKey: exceptionsKey)
            defaults?.synchronize()
        }

        /// Check if a full URL matches any exception pattern
        func isExcepted(fullURL: String) -> Bool {
            IOSDecisionCore.matchesException(fullURL, using: loadFilterRules())
        }

        // MARK: - Allowed Apps (per-app bypass)

        /// Save bundle IDs of apps that bypass filtering
        func setAllowedApps(_ bundleIDs: [String]) {
            logger.info("setAllowedApps: \(bundleIDs.count, privacy: .public) apps")
            let defaults = sharedDefaults
            defaults?.removeObject(forKey: assignedPolicyListsKey)
            defaults?.set(bundleIDs, forKey: allowedAppsKey)
            defaults?.synchronize()
        }

        /// Load allowed app bundle IDs
        func loadAllowedApps() -> [String] {
            let apps = sharedDefaults?.stringArray(forKey: allowedAppsKey) ?? []
            logger.debug("loadAllowedApps: \(apps.count, privacy: .public) apps")
            return apps
        }

        /// Check if an app is in the allowed list.
        /// Handles team ID prefix — "EQHXZ8M8AV.com.google.Gmail" matches stored "com.google.Gmail"
        func isAppAllowed(_ bundleID: String) -> Bool {
            let result = IOSDecisionCore.matchesAllowedApp(bundleID, using: loadFilterRules())
            if result {
                logger.info("isAppAllowed: \(bundleID) is allowed")
            }
            return result
        }

        // MARK: - Blocked Apps (per-app network block)

        /// Save bundle IDs of apps whose traffic should be blocked entirely
        func setBlockedApps(_ bundleIDs: [String]) {
            logger.info("setBlockedApps: \(bundleIDs.count, privacy: .public) apps")
            let defaults = sharedDefaults
            defaults?.removeObject(forKey: assignedPolicyListsKey)
            defaults?.set(bundleIDs, forKey: blockedAppsKey)
            defaults?.synchronize()
        }

        /// Load blocked app bundle IDs
        func loadBlockedApps() -> [String] {
            let apps = sharedDefaults?.stringArray(forKey: blockedAppsKey) ?? []
            logger.debug("loadBlockedApps: \(apps.count, privacy: .public) apps")
            return apps
        }

        /// Check if an app is in the blocked list.
        /// Handles team ID prefix — "EQHXZ8M8AV.com.tiktok.TikTok" matches stored "com.tiktok.TikTok"
        func isAppBlocked(_ bundleID: String) -> Bool {
            let result = IOSDecisionCore.isAppBlocked(bundleID, using: loadFilterRules())
            if result {
                logger.info("isAppBlocked: \(bundleID) is blocked")
            }
            return result
        }

        // MARK: - CDN / Related Domain Detection

        /// Returns true if the host contains a keyword from any site rule.
        func isRelatedToAllowedEntry(host: String) -> Bool {
            let items = loadSiteRules()
            guard !items.isEmpty else { return false }

            let ruleDomains = items.map(\.url)
            return IOSDecisionCore.hostContainsAnyRelatedKeyword(
                host,
                domains: ruleDomains
            )
        }
    }

// MARK: - Activity Logger

    /// Logs filter decisions to shared UserDefaults.
    /// Uses batched async writes to avoid impacting filter performance.
    class IOSActivityLogger {
        static let shared = IOSActivityLogger()

        private let appGroupIdentifier = GetBoredIdentifiers.AppGroup.ios
        private let logKey = "activity_log_entries"

        /// Maximum total entries kept in the log
        private let maxEntries = 500

        /// Pending entries waiting to be flushed to disk
        private var pendingEntries: [ActivityLogEntry] = []

        /// Flush when this many entries are pending
        private let batchSize = 50

        /// Flush after this many seconds even if batch isn't full
        private let flushInterval: TimeInterval = 2.0
        private var lastFlush = Date()

        /// Serial queue for thread-safe writes
        private let queue = DispatchQueue(
            label: GetBoredIdentifiers.Queue.iosActivityLogger, qos: .utility)

        private var sharedDefaults: UserDefaults? {
            UserDefaults(suiteName: appGroupIdentifier)
        }

        private let writeLogger = OSLog(
            subsystem: GetBoredIdentifiers.Logging.iOS, category: "IOSActivityLogger")

        // MARK: - Team ID Stripping

        /// Strip the team ID prefix from a source application identifier.
        private func stripTeamID(_ identifier: String?) -> String? {
            IOSDecisionCore.activityLogStripTeamID(identifier)
        }

        // MARK: - Logging

        /**
         * Log a filter decision. Batches writes for performance.
         *
         * Call flow:
         *
         *   filter extension calls log(domain:blocked:reason:...)
         *           │
         *           ▼
         *       build ActivityLogEntry (stripTeamID on sourceApp)
         *           │
         *           ▼
         *       queue.async { append to pendingEntries }
         *           │
         *           ├── pendingEntries.count >= 50 (batchSize)  ┐
         *           │                                            ├─→ _flushPending()
         *           └── time since lastFlush >= 2 s (flushInterval) ┘
         *                       │
         *                       ▼  (otherwise entries stay in memory)
         *                   writeEntries(toWrite)
         *                       │
         *                       ├── defaults.synchronize()  ← pull cross-process writes first
         *                       ├── decode existing [ActivityLogEntry]
         *                       ├── IOSDecisionCore.activityLogMergeAndTrim (cap at 500)
         *                       └── encode + defaults.set + defaults.synchronize()
         *
         * All writes are serialized on `queue` (serial, .utility QoS) to avoid data races.
         * Activity logging is DISABLED (2026-07-18): out of scope for iOS v1.
         * Method bodies below are commented out — not deleted — so the extension
         * call sites (FlowInspector, BlockHandler) keep compiling as no-ops and
         * the feature can be re-enabled by uncommenting. Known issue when
         * re-enabling: the 2 s flushInterval is only evaluated on the NEXT log()
         * call — no timer is ever scheduled, so a lone entry can sit in memory
         * until the extension process dies.
         */
        func log(
            domain: String,
            blocked: Bool,
            reason: String,
            sourceApp: String? = nil,
            rawEndpoint: String? = nil,
            resolutionSource: String = "legacy",
            isResolvableHostname: Bool = true
        ) {
            /**
             * Disabled implementation retained as documentation:
             * build an ActivityLogEntry, append it on `queue`, and flush when the
             * batch reaches `batchSize` or `flushInterval` has elapsed.
             */
        }

        /// Force-flush pending entries to disk (async). Disabled — see log().
        func flush() {
            // Disabled implementation: enqueue `_flushPending()` on `queue`.
        }

        /// Synchronously flush pending entries. Disabled — see log().
        func flushSync() {
            // Disabled implementation: synchronously run `_flushPending()` on `queue`.
        }

        /// Must be called on `queue`. Disabled — see log().
        private func _flushPending() {
            // Disabled implementation: drain pending entries, advance `lastFlush`, then write them.
        }

        /**
         * Read-merge-trim-write cycle on the shared activity log.
         *
         * The leading `defaults.synchronize()` is intentional: another process (the iOS app
         * reading the log for upload) may have written a tombstone or trim since this process
         * last read. Without it we'd re-inflate entries that were already cleared.
         */
        private func writeEntries(_ newEntries: [ActivityLogEntry]) {
            // Disabled implementation: synchronize, merge and trim entries with
            // `IOSDecisionCore`, then persist the encoded result in the App Group.
        }

        // MARK: - Reading

        /// Read the activity log (called from the iOS app). Disabled — see log().
        func loadEntries() -> [ActivityLogEntry] {
            // Disabled implementation: synchronize App Group defaults and decode `logKey`.
            return []
        }

        /// Clear all log entries. Disabled — see log().
        func clearLog() {
            // Disabled implementation: remove `logKey` and synchronize App Group defaults.
        }
    }
