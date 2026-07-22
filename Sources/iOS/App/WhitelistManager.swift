import Foundation
import os.log
import GetBoredCore

class WhitelistManager {
    static let shared = WhitelistManager()
    private let logger = Logger(subsystem: GetBoredIdentifiers.Logging.iOSFilterApp, category: "WhitelistManager")

    private let appGroupIdentifier = GetBoredIdentifiers.AppGroup.iosAdvanceWhitelist
    private let whitelistKey = "whitelist_items"
    private let exceptionsKey = "filter_exceptions"
    private let modeKey = "filter_mode"
    private let allowedAppsKey = "allowedAppBundleIDs"

    /// Cached UserDefaults instance. Re-creating UserDefaults(suiteName:) on every call
    /// is expensive in the filter extension hot path. The cache auto-refreshes every 5 seconds
    /// and can be explicitly invalidated via `invalidateDefaultsCache()`.
    private var _cachedDefaults: UserDefaults?
    private var _defaultsCacheTime: Date = .distantPast
    private let defaultsCacheInterval: TimeInterval = 5.0

    /// Call flow:
    ///
    ///   caller
    ///       │
    ///       ▼
    ///   sharedDefaults (computed property)
    ///       │
    ///       ├─ cache valid? (< 5 sec old) → return cached instance
    ///       │
    ///       └─ cache expired/missing
    ///           ├─ create fresh UserDefaults(suiteName:)
    ///           ├─ update cache timestamp
    ///           └─ return new instance
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

    func loadWhitelist() -> [WhitelistItem] {
        guard let data = sharedDefaults?.data(forKey: whitelistKey),
              let items = try? JSONDecoder().decode([WhitelistItem].self, from: data) else {
            logger.debug("loadWhitelist: no data found or decode failed, returning default")
            return defaultWhitelist()
        }
        logger.debug("loadWhitelist: loaded \(items.count) items")
        return items
    }

    func saveWhitelist(_ items: [WhitelistItem]) {
        guard let data = try? JSONEncoder().encode(items) else {
            logger.error("saveWhitelist: failed to encode items")
            return
        }
        logger.info("saveWhitelist: saving \(items.count) items")
        let defaults = sharedDefaults
        defaults?.set(data, forKey: whitelistKey)
        defaults?.synchronize()
    }

    /// Convenience for replacing the whole whitelist in one call from an
    /// external source (the app pulls policy via the REST API; see
    /// `FilterStatusModule`).
    func setWhitelistURLs(_ urls: [String]) {
        logger.info("setWhitelistURLs: \(urls.count) entries")
        let items = urls.map { WhitelistItem(url: $0, title: $0) }
        saveWhitelist(items)
    }

    func hasAnyEntries() -> Bool {
        !loadWhitelist().isEmpty
    }

    func isListed(url: String) -> Bool {
        KMPDecisionCoreAdapter.matchesSiteRule(url, siteRules: loadWhitelist().map(\.url))
    }

    @available(*, deprecated, renamed: "isListed(url:)")
    func isWhitelisted(url: String) -> Bool {
        isListed(url: url)
    }

    // MARK: - Exceptions

    func loadExceptions() -> [String] {
        return sharedDefaults?.stringArray(forKey: exceptionsKey) ?? []
    }

    func setExceptions(_ exceptions: [String]) {
        logger.info("setExceptions: \(exceptions.count) exceptions")
        sharedDefaults?.set(exceptions, forKey: exceptionsKey)
        sharedDefaults?.synchronize()
        logger.debug("setExceptions: exceptions persisted to shared defaults")
    }

    func isExcepted(fullURL: String) -> Bool {
        KMPDecisionCoreAdapter.matchesException(fullURL, exceptions: loadExceptions())
    }

    // MARK: - Mode

    func setMode(_ mode: String) {
        logger.info("setMode: \(mode)")
        sharedDefaults?.set(mode, forKey: modeKey)
        sharedDefaults?.synchronize()
        logger.debug("setMode: mode persisted to shared defaults")
    }

    func getMode() -> String {
        let mode = sharedDefaults?.string(forKey: modeKey) ?? FilterMode.blockSpecific.rawValue
        logger.debug("getMode: \(mode)")
        return mode
    }

    // MARK: - Allowed Apps (per-app whitelisting)

    func setAllowedApps(_ bundleIDs: [String]) {
        logger.info("setAllowedApps: \(bundleIDs.count) apps")
        sharedDefaults?.set(bundleIDs, forKey: allowedAppsKey)
        sharedDefaults?.synchronize()
        logger.debug("setAllowedApps: allowed apps persisted to shared defaults")
    }

    func loadAllowedApps() -> [String] {
        let apps = sharedDefaults?.stringArray(forKey: allowedAppsKey) ?? []
        logger.debug("loadAllowedApps: \(apps.count) apps")
        return apps
    }

    func isAppAllowed(_ bundleID: String) -> Bool {
        let result = KMPDecisionCoreAdapter.matchesAllowedApp(bundleID, allowedAppBundleIDs: loadAllowedApps())
        if result {
            logger.info("isAppAllowed: \(bundleID) is allowed")
        }
        return result
    }

    // MARK: - CDN / Related Domain Detection (keyword matching)

    /// Returns true if the host contains a keyword from any global allowlist entry.
    func isRelatedToAllowedEntry(host: String) -> Bool {
        KMPDecisionCoreAdapter.hostContainsAnyRelatedKeyword(host, domains: loadWhitelist().map(\.url))
    }

    private func defaultWhitelist() -> [WhitelistItem] {
        []
    }
}

// NOTE: IOSActivityLogger is defined in IOSRuleStore.swift (uses correct app group "group.com.getbored.ios")
