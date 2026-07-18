//
//  IOSRuleStore.swift
//  GetBored iOS Shared
//
//  Created by Tushar on 26.02.26.
//
//  Reads/writes the iOS filter rule snapshot via App Group UserDefaults.
//  Same role as MacRuleStore.swift on macOS, but reads from shared
//  UserDefaults instead of vendorConfiguration (iOS extensions resolve
//  the app group container at the same path as the user app).
//

import Foundation
import OSLog

import GetBoredCore

// MARK: - IOSRuleStore

/// Central data hub shared between the iOS app, Data Provider, and Control Provider.
/// All 3 targets read/write through shared UserDefaults via the App Group.
/// This is the single source of truth for all filter configuration.
class IOSRuleStore {
    static let shared = IOSRuleStore()
    private let logger = Logger(subsystem: GetBoredIdentifiers.Logging.iOS, category: "IOSRuleStore")

    /// App Group identifier — must match the entitlement on all 3 targets
    private let appGroupIdentifier = GetBoredIdentifiers.AppGroup.ios

    // MARK: - UserDefaults Keys

    /// JSON-encoded [SiteRule] — the blocklist/allowlist of domains
    private let siteRulesKey = "site_rules"

    /// String — "blockSpecific" or "whiteList"
    private let modeKey = "filter_mode"

    /// [String] — URL path exceptions (allowed even if domain is blocked)
    private let exceptionsKey = "filter_exceptions"

    /// [String] — bundle IDs of apps that bypass filtering entirely
    private let allowedAppsKey = "allowedAppBundleIDs"

    /// [String] — bundle IDs of apps whose traffic is blocked entirely
    private let blockedAppsKey = "blockedAppBundleIDs"

    /// JSON-encoded static Safari parent -> child domain map
    private let parentChildMapKey = GetBoredIdentifiers.SafariParentChild.parentChildMapKey

    /// JSON-encoded [ActivityLogEntry] — filter decision log
    private let logKey = "activity_log_entries"

    // MARK: - Cached UserDefaults

    /// Cached UserDefaults instance. Re-creating UserDefaults(suiteName:) on every call
    /// is expensive in the filter extension hot path. The cache auto-refreshes every 5 seconds.
    private var _cachedDefaults: UserDefaults?
    private var _defaultsCacheTime: Date = .distantPast
    private let defaultsCacheInterval: TimeInterval = 5.0

    /// Call flow:
    ///
    ///   caller accesses sharedDefaults
    ///           │
    ///           ├── cache is valid (age < 5 s) → return _cachedDefaults (no allocation)
    ///           │
    ///           └── cache is stale or nil
    ///                   │
    ///                   ▼
    ///               UserDefaults(suiteName: appGroupIdentifier)   ← new instance
    ///               _defaultsCacheTime = now
    ///               return _cachedDefaults
    ///
    /// The 5-second TTL exists because UserDefaults(suiteName:) is expensive to
    /// allocate on every call, yet the filter extension needs cross-process data
    /// that another process may have written since the last read.
    private var sharedDefaults: UserDefaults? {
        let now = Date()
        if _cachedDefaults == nil || now.timeIntervalSince(_defaultsCacheTime) > defaultsCacheInterval {
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
    func loadSiteRules() -> [SiteRule] {
        guard let data = sharedDefaults?.data(forKey: siteRulesKey),
              let items = try? JSONDecoder().decode([SiteRule].self, from: data) else {
            logger.debug("loadSiteRules: no data found or decode failed, returning empty")
            return []
        }
        logger.debug("loadSiteRules: loaded \(items.count) items")
        return items
    }

    /// Load the full policy snapshot expected by the shared decision core.
    ///
    /// This is the single chokepoint all consumers (FlowInspector, KMPDecisionCoreAdapter,
    /// isListed/isExcepted/isAppAllowed/isAppBlocked below) go through to get a filter mode —
    /// see decodedFilterMode() for the block-mode-only safety guard applied here.
    ///
    /// Call flow:
    ///
    ///   filter extension (hot path) calls loadFilterRules()
    ///           │
    ///           ├── decodedFilterMode()  → FilterMode (block-mode-only guard; never .whiteList)
    ///           ├── loadSiteRules()     → [SiteRule] from JSON in UserDefaults
    ///           ├── loadExceptions()   → [String] from UserDefaults
    ///           ├── loadAllowedApps()  → [String] from UserDefaults
    ///           └── loadBlockedApps()  → [String] from UserDefaults
    ///                   │
    ///                   ▼
    ///               LoadedFilterRules (passed to KMPDecisionCoreAdapter for every decision)
    ///
    /// All five reads hit the same cached UserDefaults instance (5-second TTL).
    func loadFilterRules() -> LoadedFilterRules {
        return LoadedFilterRules(
            siteRules: loadSiteRules(),
            filterMode: decodedFilterMode(),
            exceptions: loadExceptions(),
            allowedAppBundleIDs: loadAllowedApps(),
            blockedAppBundleIDs: loadBlockedApps()
        )
    }

    /// Save site rules to shared UserDefaults
    func saveSiteRules(_ items: [SiteRule]) {
        guard let data = try? JSONEncoder().encode(items) else {
            logger.error("saveSiteRules: failed to encode items")
            return
        }
        logger.info("saveSiteRules: saving \(items.count) items")
        let defaults = sharedDefaults
        defaults?.set(data, forKey: siteRulesKey)
        defaults?.synchronize()
    }

    /// Save the server-generated Safari parent-child map to shared UserDefaults.
    /// The AppProxy and Data Provider decode the typed schema when making decisions.
    @discardableResult
    func saveParentChildMapJSON(_ json: String) -> Bool {
        guard KMPDecisionCoreAdapter.isValidParentChildMapJSON(json) else {
            logger.error("saveParentChildMapJSON: invalid JSON")
            return false
        }

        logger.info("saveParentChildMapJSON: saving \(json.utf8.count) bytes")
        let defaults = sharedDefaults
        defaults?.set(json, forKey: parentChildMapKey)
        defaults?.synchronize()
        return true
    }

    /// Check if a host matches any site rule (exact or subdomain match)
    func isListed(url: String) -> Bool {
        KMPDecisionCoreAdapter.matchesSiteRule(url, using: loadFilterRules())
    }

    /// Returns true if there are any site rules configured
    func hasAnyEntries() -> Bool {
        !loadFilterRules().siteRules.isEmpty
    }

    // MARK: - Filter List Snapshot

    /// Atomically overwrites the full filter policy with a merged snapshot from CloudKit.
    ///
    /// Call flow:
    ///
    ///   syncFilterLists resolves assigned+active FilterLists from CloudKit
    ///           │
    ///           ▼
    ///   applyFilterListSnapshot(mode:entries:exceptions:allowedApps:blockedApps:)
    ///           │
    ///           ├── convert [String] entries → [SiteRule] (url = title = entry)
    ///           ├── convert FilterListMode → FilterMode (same raw value)
    ///           ├── write siteRulesKey, modeKey, exceptionsKey, allowedAppsKey, blockedAppsKey in one defaults batch
    ///           ├── defaults.synchronize()  ← flush cross-process so extension sees new values
    ///           └── invalidateDefaultsCache()  ← force next read to re-create UserDefaults instance
    ///
    /// All five keys are written before synchronize() so the extension never sees a partial state.
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

        if let data = try? JSONEncoder().encode(siteRules) {
            defaults?.set(data, forKey: siteRulesKey)
        }
        defaults?.set(filterMode.rawValue, forKey: modeKey)
        defaults?.set(exceptions, forKey: exceptionsKey)
        defaults?.set(allowedApps, forKey: allowedAppsKey)
        defaults?.set(blockedApps, forKey: blockedAppsKey)
        defaults?.synchronize()

        invalidateDefaultsCache()

        logger.info("applyFilterListSnapshot: \(entries.count) entries, mode=\(filterMode.rawValue), \(exceptions.count) exceptions, \(allowedApps.count) allowedApps, \(blockedApps.count) blockedApps")
    }

    // MARK: - Filter Mode

    /// Set the filter mode ("blockSpecific" or "whiteList")
    func setMode(_ mode: String) {
        logger.info("setMode: \(mode)")
        sharedDefaults?.set(mode, forKey: modeKey)
        sharedDefaults?.synchronize()
    }

    /// Get the current filter mode (defaults to "blockSpecific"). Goes through
    /// decodedFilterMode() so a stored `.whiteList` value is never surfaced here either —
    /// this is also what the React Native "Active Rules" screen reads for display.
    func getMode() -> String {
        let mode = decodedFilterMode().rawValue
        logger.debug("getMode: \(mode)")
        return mode
    }

    /// Decodes the stored filter mode, defensively coercing `.whiteList` to `.blockSpecific`.
    ///
    /// v1 ships BLOCK MODE ONLY — the parent-child Safari whitelist machinery
    /// (allowedSafariParent, the two Safari extensions, the App-Proxy provider) was removed
    /// from this build. A CloudKit-synced FilterList (or a stale UserDefaults value written
    /// before the block-mode-only cutover) can still carry `mode == .whiteList` — that is a
    /// valid raw value, so the plain `FilterMode(rawValue:)` decode below does not catch it.
    /// Letting it reach the decision core would either exercise removed machinery or, worse,
    /// silently degrade into an unfiltered pass-through. Coerce it to the safe block-mode
    /// default instead — this must NEVER coerce toward "allow everything".
    ///
    /// Call flow:
    ///
    ///   loadFilterRules() / getMode() → decodedFilterMode()
    ///           │
    ///           ├── sharedDefaults?.string(forKey: modeKey)   → raw string (fallback: "blockSpecific")
    ///           ├── FilterMode(rawValue:)                     → decoded mode (fallback: .blockSpecific)
    ///           │
    ///           ├── decoded == .blockSpecific → return unchanged (fast path)
    ///           └── decoded == .whiteList
    ///                   └── log warning, return .blockSpecific   ← safe default, never allow-all
    private func decodedFilterMode() -> FilterMode {
        let rawMode = sharedDefaults?.string(forKey: modeKey) ?? FilterMode.blockSpecific.rawValue
        let decodedMode = FilterMode(rawValue: rawMode) ?? .blockSpecific

        guard decodedMode == .whiteList else {
            return decodedMode
        }

        logger.warning("decodedFilterMode: whiteList mode received in block-mode-only build; coercing to block-mode default (whitelist machinery removed in v1)")
        return .blockSpecific
    }

    // MARK: - Exceptions (URL path exemptions)

    /// Load exception patterns (e.g. "instagram.com/school-account")
    func loadExceptions() -> [String] {
        return sharedDefaults?.stringArray(forKey: exceptionsKey) ?? []
    }

    /// Save exception patterns
    func setExceptions(_ exceptions: [String]) {
        logger.info("setExceptions: \(exceptions.count) exceptions")
        sharedDefaults?.set(exceptions, forKey: exceptionsKey)
        sharedDefaults?.synchronize()
    }

    /// Check if a full URL matches any exception pattern
    func isExcepted(fullURL: String) -> Bool {
        KMPDecisionCoreAdapter.matchesException(fullURL, using: loadFilterRules())
    }

    // MARK: - Allowed Apps (per-app bypass)

    /// Save bundle IDs of apps that bypass filtering
    func setAllowedApps(_ bundleIDs: [String]) {
        logger.info("setAllowedApps: \(bundleIDs.count) apps")
        sharedDefaults?.set(bundleIDs, forKey: allowedAppsKey)
        sharedDefaults?.synchronize()
    }

    /// Load allowed app bundle IDs
    func loadAllowedApps() -> [String] {
        let apps = sharedDefaults?.stringArray(forKey: allowedAppsKey) ?? []
        logger.debug("loadAllowedApps: \(apps.count) apps")
        return apps
    }

    /// Check if an app is in the allowed list.
    /// Handles team ID prefix — "EQHXZ8M8AV.com.google.Gmail" matches stored "com.google.Gmail"
    func isAppAllowed(_ bundleID: String) -> Bool {
        let result = KMPDecisionCoreAdapter.matchesAllowedApp(bundleID, using: loadFilterRules())
        if result {
            logger.info("isAppAllowed: \(bundleID) is allowed")
        }
        return result
    }

    // MARK: - Blocked Apps (per-app network block)

    /// Save bundle IDs of apps whose traffic should be blocked entirely
    func setBlockedApps(_ bundleIDs: [String]) {
        logger.info("setBlockedApps: \(bundleIDs.count) apps")
        sharedDefaults?.set(bundleIDs, forKey: blockedAppsKey)
        sharedDefaults?.synchronize()
    }

    /// Load blocked app bundle IDs
    func loadBlockedApps() -> [String] {
        let apps = sharedDefaults?.stringArray(forKey: blockedAppsKey) ?? []
        logger.debug("loadBlockedApps: \(apps.count) apps")
        return apps
    }

    /// Check if an app is in the blocked list.
    /// Handles team ID prefix — "EQHXZ8M8AV.com.tiktok.TikTok" matches stored "com.tiktok.TikTok"
    func isAppBlocked(_ bundleID: String) -> Bool {
        let result = KMPDecisionCoreAdapter.isAppBlocked(bundleID, using: loadFilterRules())
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
        return KMPDecisionCoreAdapter.hostContainsAnyRelatedKeyword(
            host,
            domains: items.map(\.url)
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
    private let queue = DispatchQueue(label: GetBoredIdentifiers.Queue.iosActivityLogger, qos: .utility)

    private var sharedDefaults: UserDefaults? {
        UserDefaults(suiteName: appGroupIdentifier)
    }

    private let writeLogger = OSLog(subsystem: GetBoredIdentifiers.Logging.iOS, category: "IOSActivityLogger")

    // MARK: - Team ID Stripping

    /// Strip team ID prefix from sourceAppIdentifier. Delegates to Kotlin ActivityLogPolicy.
    private func stripTeamID(_ identifier: String?) -> String? {
        KMPDecisionCoreAdapter.activityLogStripTeamID(identifier)
    }

    // MARK: - Logging

    /// Log a filter decision. Batches writes for performance.
    ///
    /// Call flow:
    ///
    ///   filter extension calls log(domain:blocked:reason:...)
    ///           │
    ///           ▼
    ///       build ActivityLogEntry (stripTeamID on sourceApp)
    ///           │
    ///           ▼
    ///       queue.async { append to pendingEntries }
    ///           │
    ///           ├── pendingEntries.count >= 50 (batchSize)  ┐
    ///           │                                            ├─→ _flushPending()
    ///           └── time since lastFlush >= 2 s (flushInterval) ┘
    ///                       │
    ///                       ▼  (otherwise entries stay in memory)
    ///                   writeEntries(toWrite)
    ///                       │
    ///                       ├── defaults.synchronize()  ← pull cross-process writes first
    ///                       ├── decode existing [ActivityLogEntry]
    ///                       ├── KMPDecisionCoreAdapter.activityLogMergeAndTrim (cap at 500)
    ///                       └── encode + defaults.set + defaults.synchronize()
    ///
    /// All writes are serialized on `queue` (serial, .utility QoS) to avoid data races.
    // Activity logging is DISABLED (2026-07-18): out of scope for iOS v1.
    // Method bodies below are commented out — not deleted — so the extension
    // call sites (FlowInspector, BlockHandler) keep compiling as no-ops and
    // the feature can be re-enabled by uncommenting. Known issue when
    // re-enabling: the 2 s flushInterval is only evaluated on the NEXT log()
    // call — no timer is ever scheduled, so a lone entry can sit in memory
    // until the extension process dies.
    func log(domain: String,
             blocked: Bool,
             reason: String,
             sourceApp: String? = nil,
             rawEndpoint: String? = nil,
             resolutionSource: String = "legacy",
             isResolvableHostname: Bool = true) {
        /*
        let entry = ActivityLogEntry(
            displayDomain: domain,
            blocked: blocked,
            reason: reason,
            sourceApp: stripTeamID(sourceApp),
            rawEndpoint: rawEndpoint,
            resolutionSource: resolutionSource,
            isResolvableHostname: isResolvableHostname
        )
        queue.async { [weak self] in
            guard let self else { return }
            self.pendingEntries.append(entry)
            let shouldFlush = self.pendingEntries.count >= self.batchSize ||
                Date().timeIntervalSince(self.lastFlush) >= self.flushInterval
            if shouldFlush {
                self._flushPending()
            }
        }
        */
    }

    /// Force-flush pending entries to disk (async). Disabled — see log().
    func flush() {
        /*
        queue.async { [weak self] in
            self?._flushPending()
        }
        */
    }

    /// Synchronously flush pending entries. Disabled — see log().
    func flushSync() {
        /*
        queue.sync { [weak self] in
            self?._flushPending()
        }
        */
    }

    /// Must be called on `queue`. Disabled — see log().
    private func _flushPending() {
        /*
        guard !pendingEntries.isEmpty else { return }
        let toWrite = pendingEntries
        pendingEntries = []
        lastFlush = Date()
        writeEntries(toWrite)
        */
    }

    /// Read-merge-trim-write cycle on the shared activity log.
    ///
    /// The leading `defaults.synchronize()` is intentional: another process (the iOS app
    /// reading the log for upload) may have written a tombstone or trim since this process
    /// last read. Without it we'd re-inflate entries that were already cleared.
    private func writeEntries(_ newEntries: [ActivityLogEntry]) {
        /*
        guard let defaults = sharedDefaults else {
            os_log("IOSActivityLogger.writeEntries: sharedDefaults is nil!", log: writeLogger, type: .error)
            return
        }
        defaults.synchronize()

        var existing: [ActivityLogEntry] = []
        if let data = defaults.data(forKey: logKey) {
            existing = (try? JSONDecoder().decode([ActivityLogEntry].self, from: data)) ?? []
        }

        existing = KMPDecisionCoreAdapter.activityLogMergeAndTrim(
            existing: existing,
            newEntries: newEntries,
            maxTotal: maxEntries
        )

        if let data = try? JSONEncoder().encode(existing) {
            defaults.set(data, forKey: logKey)
            defaults.synchronize()
        }
        */
    }

    // MARK: - Reading

    /// Read the activity log (called from the iOS app). Disabled — see log().
    func loadEntries() -> [ActivityLogEntry] {
        /*
        guard let defaults = sharedDefaults else { return [] }
        defaults.synchronize()
        guard let data = defaults.data(forKey: logKey) else { return [] }
        return (try? JSONDecoder().decode([ActivityLogEntry].self, from: data)) ?? []
        */
        return []
    }

    /// Clear all log entries. Disabled — see log().
    func clearLog() {
        /*
        sharedDefaults?.removeObject(forKey: logKey)
        sharedDefaults?.synchronize()
        */
    }
}
