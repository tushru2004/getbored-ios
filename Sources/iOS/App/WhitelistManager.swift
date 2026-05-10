import Foundation
import os.log

class WhitelistManager {
    static let shared = WhitelistManager()
    private let logger = Logger(subsystem: GetBoredIdentifiers.Logging.iOSFilterApp, category: "WhitelistManager")

    private let appGroupIdentifier = GetBoredIdentifiers.AppGroup.iosAdvanceWhitelist
    private let whitelistKey = "whitelist_items"
    private let locationEntriesKey = "location_blocked_entries"
    private let locationListsConfiguredKey = "location_lists_configured"
    private let locationModeKey = "location_mode"
    private let exceptionsKey = "filter_exceptions"
    private let modeKey = "filter_mode"
    private let allowedAppsKey = "allowedAppBundleIDs"

    /// Cached UserDefaults instance. Re-creating UserDefaults(suiteName:) on every call
    /// is expensive in the filter extension hot path. The cache auto-refreshes every 5 seconds
    /// and can be explicitly invalidated via `invalidateDefaultsCache()`.
    private var _cachedDefaults: UserDefaults?
    private var _defaultsCacheTime: Date = .distantPast
    private let defaultsCacheInterval: TimeInterval = 5.0

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

    /// Convenience for syncing from CloudKit / external sources.
    func setWhitelistURLs(_ urls: [String]) {
        logger.info("setWhitelistURLs: \(urls.count) entries")
        let items = urls.map { WhitelistItem(url: $0, title: $0) }
        saveWhitelist(items)
    }

    func hasAnyEntries() -> Bool {
        !loadWhitelist().isEmpty || hasLocationEntries() || hasLocationListsConfigured()
    }

    // MARK: - Location Entries (separate from main whitelist)

    func setLocationEntries(_ entries: [String]) {
        logger.info("setLocationEntries: \(entries.count) entries")
        sharedDefaults?.set(entries, forKey: locationEntriesKey)
        sharedDefaults?.synchronize()
        logger.debug("setLocationEntries: entries persisted to shared defaults")
    }

    func loadLocationEntries() -> [String] {
        let entries = sharedDefaults?.stringArray(forKey: locationEntriesKey) ?? []
        logger.debug("loadLocationEntries: \(entries.count) entries")
        return entries
    }

    func hasLocationEntries() -> Bool {
        !loadLocationEntries().isEmpty
    }

    /// Tracks whether any location-based filter lists are configured (even if not currently active).
    /// Prevents the no-entries lockdown from triggering when outside all geofences.
    func setLocationListsConfigured(_ configured: Bool) {
        sharedDefaults?.set(configured, forKey: locationListsConfiguredKey)
        sharedDefaults?.synchronize()
    }

    func hasLocationListsConfigured() -> Bool {
        return sharedDefaults?.bool(forKey: locationListsConfiguredKey) ?? false
    }

    /// The mode of the currently active location lists (whiteList or nil).
    /// When set to "whiteList", location entries are treated as ALLOWED sites.
    func setLocationMode(_ mode: String?) {
        if let mode = mode {
            sharedDefaults?.set(mode, forKey: locationModeKey)
        } else {
            sharedDefaults?.removeObject(forKey: locationModeKey)
        }
        sharedDefaults?.synchronize()
    }

    func getLocationMode() -> String? {
        return sharedDefaults?.string(forKey: locationModeKey)
    }

    func isLocationListed(url: String) -> Bool {
        let entries = loadLocationEntries()
        guard !entries.isEmpty else { return false }
        let host = extractDomain(from: url).lowercased()
        guard !host.isEmpty else { return false }
        return entries.contains { entry in
            let domain = extractDomain(from: entry).lowercased()
            return host == domain || host.hasSuffix("." + domain)
        }
    }

    /// Returns true if location-based lists exist but location permission was denied.
    /// The filter extension should block all non-system traffic in this case.
    func isLocationLockdownActive() -> Bool {
        return sharedDefaults?.bool(forKey: "location_permission_denied_lockdown") ?? false
    }

    func isListed(url: String) -> Bool {
        let items = loadWhitelist()
        let host = extractDomain(from: url).lowercased()
        guard !host.isEmpty else { return false }
        return items.contains { item in
            let domain = extractDomain(from: item.url).lowercased()
            // Exact match or subdomain match (e.g. "www.google.com" matches "google.com")
            return host == domain || host.hasSuffix("." + domain)
        }
    }

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
        let exceptions = loadExceptions()
        guard !exceptions.isEmpty else { return false }
        var normalized = fullURL.lowercased()
        if let range = normalized.range(of: "://") {
            normalized = String(normalized[range.upperBound...])
        }
        if normalized.hasPrefix("www.") {
            normalized = String(normalized.dropFirst(4))
        }
        for exception in exceptions {
            var pattern = exception.lowercased()
            if let range = pattern.range(of: "://") {
                pattern = String(pattern[range.upperBound...])
            }
            if pattern.hasPrefix("www.") {
                pattern = String(pattern.dropFirst(4))
            }
            if normalized.hasPrefix(pattern) { return true }
        }
        return false
    }

    // MARK: - Mode

    func setMode(_ mode: String) {
        logger.info("setMode: \(mode)")
        sharedDefaults?.set(mode, forKey: modeKey)
        sharedDefaults?.synchronize()
        logger.debug("setMode: mode persisted to shared defaults")
    }

    func getMode() -> String {
        let mode = sharedDefaults?.string(forKey: modeKey) ?? "blockSpecific"
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
        let allowed = loadAllowedApps()
        guard !allowed.isEmpty else { return false }
        let id = bundleID.lowercased()
        // Match both exact and suffix — sourceAppIdentifier may have team prefix
        // e.g., "EQHXZ8M8AV.com.google.Gmail" should match stored "com.google.Gmail"
        let result = allowed.contains { stored in
            let s = stored.lowercased()
            return s == id || id.hasSuffix(".\(s)")
        }
        if result {
            logger.info("isAppAllowed: \(bundleID) is allowed")
        }
        return result
    }

    // MARK: - CDN / Related Domain Detection (keyword matching)

    /// Extracts the "base keyword" from a domain for CDN matching.
    /// e.g. "amazon.de" → "amazon", "maps.google.com" → "google", "uber.com" → "uber"
    private func baseKeyword(from domain: String) -> String? {
        let parts = domain.lowercased().split(separator: ".")
        guard parts.count >= 2 else { return nil }
        // Take the second-to-last part (SLD): "amazon" from "amazon.de", "google" from "google.com"
        let sld = String(parts[parts.count - 2])
        // Skip very short or generic keywords that would match too broadly
        guard sld.count >= 4 else { return nil }
        return sld
    }

    /// Returns true if the host contains a keyword from any location entry.
    /// e.g. host "images-eu.ssl-images-amazon.com" contains "amazon" from entry "amazon.de"
    func isRelatedToLocationEntry(host: String) -> Bool {
        let entries = loadLocationEntries()
        guard !entries.isEmpty else { return false }
        let h = host.lowercased()
        return entries.contains { entry in
            guard let keyword = baseKeyword(from: extractDomain(from: entry)) else { return false }
            return h.contains(keyword)
        }
    }

    /// Returns true if the host contains a keyword from any global allowlist entry.
    func isRelatedToAllowedEntry(host: String) -> Bool {
        let items = loadWhitelist()
        guard !items.isEmpty else { return false }
        let h = host.lowercased()
        return items.contains { item in
            guard let keyword = baseKeyword(from: extractDomain(from: item.url)) else { return false }
            return h.contains(keyword)
        }
    }

    /// Extract the domain from a URL string or hostname.
    private func extractDomain(from input: String) -> String {
        // Strip scheme if present
        var s = input
        if let range = s.range(of: "://") {
            s = String(s[range.upperBound...])
        }
        // Strip path, port, query
        if let slash = s.firstIndex(of: "/") { s = String(s[..<slash]) }
        if let colon = s.firstIndex(of: ":") { s = String(s[..<colon]) }
        if let question = s.firstIndex(of: "?") { s = String(s[..<question]) }
        return s
    }

    private func defaultWhitelist() -> [WhitelistItem] {
        []
    }
}

// NOTE: IOSActivityLogger is defined in IOSRuleStore.swift (uses correct app group "group.com.getbored.ios")
