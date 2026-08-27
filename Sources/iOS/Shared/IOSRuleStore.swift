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
import GetBoredCore
import OSLog

// MARK: - IOSRuleStore

/// Shared App Group storage for the iOS filter policy.
///
/// The app writes the server policy here. The Data and Control Providers read
/// the same snapshot, then `IOSDecisionCore` evaluates it. This store moves
/// data between targets; it does not make allow or block decisions.
class IOSRuleStore {
    static let shared = IOSRuleStore()
    private let logger = Logger(
        subsystem: GetBoredIdentifiers.Logging.iOS, category: "IOSRuleStore")

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
    func loadSiteRules() -> [SiteRule] {
        guard let data = sharedDefaults?.data(forKey: siteRulesKey),
            let items = try? JSONDecoder().decode([SiteRule].self, from: data)
        else {
            logger.debug("loadSiteRules: no data found or decode failed, returning empty")
            return []
        }
        logger.debug("loadSiteRules: loaded \(items.count, privacy: .public) items")
        return items
    }

    /// Load the full policy snapshot expected by the shared decision core.
    ///
    /// This is the single chokepoint all consumers (FlowInspector, IOSDecisionCore,
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
    ///               LoadedFilterRules (passed to IOSDecisionCore for every decision)
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
        logger.info("saveSiteRules: saving \(items.count, privacy: .public) items")
        let defaults = sharedDefaults
        defaults?.set(data, forKey: siteRulesKey)
        defaults?.synchronize()
    }

    /// Validates and publishes the server-generated Safari parent-child map.
    /// The App Proxy and Data Provider later decode the typed schema when making
    /// spike decisions.
    ///
    /// Call flow:
    ///
    ///   policy sync receives parent-child JSON → saveParentChildMapJSON(json)
    ///           │
    ///           ├── IOSDecisionCore.isValidParentChildMapJSON(json) == false
    ///           │       └── log error → return false  ← preserve the previous map
    ///           │
    ///           └── JSON is valid
    ///                   └── defaults[parentChildMapKey] = json → synchronize() → return true
    @discardableResult
    func saveParentChildMapJSON(_ json: String) -> Bool {
        guard IOSDecisionCore.isValidParentChildMapJSON(json) else {
            logger.error("saveParentChildMapJSON: invalid JSON")
            return false
        }

        logger.info("saveParentChildMapJSON: saving \(json.utf8.count, privacy: .public) bytes")
        let defaults = sharedDefaults
        defaults?.set(json, forKey: parentChildMapKey)
        defaults?.synchronize()
        return true
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

    /// Replaces the full filter policy with a server-merged snapshot.
    ///
    /// `syncFilterLists` fetches the already-merged result from `GET /api/policy`
    /// and hands it straight to this writer.
    ///
    /// Call flow:
    ///
    ///   syncFilterLists fetches this device's merged policy from GET /api/policy
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
    /// All five keys are written before `synchronize()` asks the shared defaults
    /// store to publish the new snapshot to the extension processes.
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

        logger.info(
            "applyFilterListSnapshot: \(entries.count, privacy: .public) entries, mode=\(filterMode.rawValue, privacy: .public), \(exceptions.count, privacy: .public) exceptions, \(allowedApps.count, privacy: .public) allowedApps, \(blockedApps.count, privacy: .public) blockedApps"
        )
    }

    // MARK: - Filter Mode

    /// Set the filter mode ("blockSpecific" or "whiteList")
    func setMode(_ mode: String) {
        logger.info("setMode: \(mode, privacy: .public)")
        sharedDefaults?.set(mode, forKey: modeKey)
        sharedDefaults?.synchronize()
    }

    /// Get the current filter mode (defaults to "blockSpecific"). Goes through
    /// decodedFilterMode() so a stored `.whiteList` value is never surfaced here either —
    /// this is also what the React Native "Active Rules" screen reads for display.
    func getMode() -> String {
        let mode = decodedFilterMode().rawValue
        logger.debug("getMode: \(mode, privacy: .public)")
        return mode
    }

    /// Decodes the stored filter mode, defensively coercing `.whiteList` to `.blockSpecific`.
    ///
    /// v1 ships BLOCK MODE ONLY — the parent-child Safari whitelist machinery
    /// (allowedSafariParent, the two Safari extensions, the App-Proxy provider) was removed
    /// from this build. A server-synced FilterList (or a stale UserDefaults value written
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
        let requiresBlockModeCoercion = decodedMode == .whiteList

        guard requiresBlockModeCoercion else {
            return decodedMode
        }

        logger.warning(
            "decodedFilterMode: whiteList mode received in block-mode-only build; coercing to block-mode default (whitelist machinery removed in v1)"
        )
        return .blockSpecific
    }

    // MARK: - Exceptions (URL path exemptions)

    /// Load exception patterns (e.g. "instagram.com/school-account")
    func loadExceptions() -> [String] {
        return sharedDefaults?.stringArray(forKey: exceptionsKey) ?? []
    }

    /// Save exception patterns
    func setExceptions(_ exceptions: [String]) {
        logger.info("setExceptions: \(exceptions.count, privacy: .public) exceptions")
        sharedDefaults?.set(exceptions, forKey: exceptionsKey)
        sharedDefaults?.synchronize()
    }

    /// Check if a full URL matches any exception pattern
    func isExcepted(fullURL: String) -> Bool {
        IOSDecisionCore.matchesException(fullURL, using: loadFilterRules())
    }

    // MARK: - Allowed Apps (per-app bypass)

    /// Save bundle IDs of apps that bypass filtering
    func setAllowedApps(_ bundleIDs: [String]) {
        logger.info("setAllowedApps: \(bundleIDs.count, privacy: .public) apps")
        sharedDefaults?.set(bundleIDs, forKey: allowedAppsKey)
        sharedDefaults?.synchronize()
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
        sharedDefaults?.set(bundleIDs, forKey: blockedAppsKey)
        sharedDefaults?.synchronize()
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
    ///                       ├── IOSDecisionCore.activityLogMergeAndTrim (cap at 500)
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
    func log(
        domain: String,
        blocked: Bool,
        reason: String,
        sourceApp: String? = nil,
        rawEndpoint: String? = nil,
        resolutionSource: String = "legacy",
        isResolvableHostname: Bool = true
    ) {
        // Disabled implementation retained as documentation:
        // build an ActivityLogEntry, append it on `queue`, and flush when the
        // batch reaches `batchSize` or `flushInterval` has elapsed.
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

    /// Read-merge-trim-write cycle on the shared activity log.
    ///
    /// The leading `defaults.synchronize()` is intentional: another process (the iOS app
    /// reading the log for upload) may have written a tombstone or trim since this process
    /// last read. Without it we'd re-inflate entries that were already cleared.
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
