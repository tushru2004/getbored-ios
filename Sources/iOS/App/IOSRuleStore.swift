//
//  IOSRuleStore.swift
//  GetBored
//
//  Created by Tushar on 26.02.26.
//
//  Reads/writes the iOS filter rule snapshot via App Group UserDefaults.
//  Same role as MacRuleStore.swift on macOS, but reads from shared
//  UserDefaults instead of vendorConfiguration (iOS extensions resolve
//  the app group container at the same path as the user app).
//

import Foundation
import os.log

// MARK: - IOSRuleStore

/// Central data hub shared between the iOS app, Data Provider, and Control Provider.
/// All 3 targets read/write through shared UserDefaults via the App Group.
/// This is the single source of truth for all filter configuration.
class IOSRuleStore {
    static let shared = IOSRuleStore()
    private let logger = Logger(subsystem: "com.getbored.ios", category: "IOSRuleStore")

    /// App Group identifier — must match the entitlement on all 3 targets
    private let appGroupIdentifier = "group.com.getbored.ios"

    // MARK: - UserDefaults Keys

    /// JSON-encoded [SiteRule] — the blocklist/allowlist of domains
    private let siteRulesKey = "site_rules"

    /// String — "blockSpecific" or "whiteList"
    private let modeKey = "filter_mode"

    /// [String] — URL path exceptions (allowed even if domain is blocked)
    private let exceptionsKey = "filter_exceptions"

    /// [String] — bundle IDs of apps that bypass filtering entirely
    private let allowedAppsKey = "allowedAppBundleIDs"

    /// JSON-encoded static Safari parent -> child domain map
    private let parentChildMapKey = "parent_child_map_v1"

    /// JSON-encoded [ActivityLogEntry] — filter decision log
    private let logKey = "activity_log_entries"

    // MARK: - Cached UserDefaults

    /// Cached UserDefaults instance. Re-creating UserDefaults(suiteName:) on every call
    /// is expensive in the filter extension hot path. The cache auto-refreshes every 5 seconds.
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
        guard let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["schemaVersion"] as? Int == 1,
              object["rules"] as? [[String: Any]] != nil else {
            logger.error("saveParentChildMapJSON: invalid JSON")
            return false
        }

        logger.info("saveParentChildMapJSON: saving \(data.count) bytes")
        let defaults = sharedDefaults
        defaults?.set(json, forKey: parentChildMapKey)
        defaults?.synchronize()
        return true
    }

    /// Check if a host matches any site rule (exact or subdomain match)
    func isListed(url: String) -> Bool {
        let items = loadSiteRules()
        let host = extractDomain(from: url).lowercased()
        guard !host.isEmpty else { return false }
        return items.contains { item in
            let domain = extractDomain(from: item.url).lowercased()
            return host == domain || host.hasSuffix("." + domain)
        }
    }

    /// Returns true if there are any site rules configured
    func hasAnyEntries() -> Bool {
        !loadSiteRules().isEmpty
    }

    // MARK: - Filter Mode

    /// Set the filter mode ("blockSpecific" or "whiteList")
    func setMode(_ mode: String) {
        logger.info("setMode: \(mode)")
        sharedDefaults?.set(mode, forKey: modeKey)
        sharedDefaults?.synchronize()
    }

    /// Get the current filter mode (defaults to "blockSpecific")
    func getMode() -> String {
        let mode = sharedDefaults?.string(forKey: modeKey) ?? "blockSpecific"
        logger.debug("getMode: \(mode)")
        return mode
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
        let exceptions = loadExceptions()
        guard !exceptions.isEmpty else { return false }

        // Normalize: strip scheme and "www."
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
        let allowed = loadAllowedApps()
        guard !allowed.isEmpty else { return false }
        let id = bundleID.lowercased()
        let result = allowed.contains { stored in
            let lowered = stored.lowercased()
            return lowered == id || id.hasSuffix(".\(lowered)")
        }
        if result {
            logger.info("isAppAllowed: \(bundleID) is allowed")
        }
        return result
    }

    // MARK: - CDN / Related Domain Detection

    /// Extracts the "base keyword" from a domain for CDN matching.
    /// e.g. "amazon.de" -> "amazon", "maps.google.com" -> "google"
    private func baseKeyword(from domain: String) -> String? {
        let parts = domain.lowercased().split(separator: ".")
        guard parts.count >= 2 else { return nil }
        let sld = String(parts[parts.count - 2])
        // Skip short/generic keywords that would match too broadly
        guard sld.count >= 4 else { return nil }
        return sld
    }

    /// Returns true if the host contains a keyword from any site rule.
    func isRelatedToAllowedEntry(host: String) -> Bool {
        let items = loadSiteRules()
        guard !items.isEmpty else { return false }
        let lowered = host.lowercased()
        return items.contains { item in
            guard let keyword = baseKeyword(from: extractDomain(from: item.url)) else { return false }
            return lowered.contains(keyword)
        }
    }

    // MARK: - Helpers

    /// Extract the domain from a URL string or hostname.
    /// Strips scheme, path, port, and query string.
    private func extractDomain(from input: String) -> String {
        var str = input
        if let range = str.range(of: "://") {
            str = String(str[range.upperBound...])
        }
        if let slash = str.firstIndex(of: "/") { str = String(str[..<slash]) }
        if let colon = str.firstIndex(of: ":") { str = String(str[..<colon]) }
        if let question = str.firstIndex(of: "?") { str = String(str[..<question]) }
        return str
    }
}

// MARK: - Activity Logger

/// Logs filter decisions to shared UserDefaults.
/// Uses batched async writes to avoid impacting filter performance.
class IOSActivityLogger {
    static let shared = IOSActivityLogger()

    private let appGroupIdentifier = "group.com.getbored.ios"
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
    private let queue = DispatchQueue(label: "com.getbored.activitylogger", qos: .utility)

    private var sharedDefaults: UserDefaults? {
        UserDefaults(suiteName: appGroupIdentifier)
    }

    private let writeLogger = OSLog(subsystem: "com.getbored.ios", category: "IOSActivityLogger")

    // MARK: - Team ID Stripping

    /// Strip team ID prefix from sourceAppIdentifier.
    /// NEFilterFlow.sourceAppIdentifier returns "TEAMID.com.bundle.id" — we want just "com.bundle.id"
    private func stripTeamID(_ identifier: String?) -> String? {
        guard let identifier, !identifier.isEmpty else { return nil }
        let prefixes = ["com.", "org.", "net.", "de.", "io.", "me.", "app.", "co.", "uk.", "fr.", "jp.", "au.", "at."]
        for prefix in prefixes {
            if let range = identifier.range(of: prefix) {
                return String(identifier[range.lowerBound...])
            }
        }
        // If no known prefix, check for team ID pattern (uppercase alphanumeric, ~10 chars)
        let parts = identifier.split(separator: ".")
        if parts.count >= 3 {
            let first = String(parts[0])
            if first.count >= 8 && first.allSatisfy({ $0.isUppercase || $0.isNumber }) {
                return parts.dropFirst().joined(separator: ".")
            }
        }
        return identifier
    }

    // MARK: - Logging

    /// Log a filter decision. Batches writes for performance.
    func log(domain: String,
             blocked: Bool,
             reason: String,
             sourceApp: String? = nil,
             rawEndpoint: String? = nil,
             resolutionSource: String = "legacy",
             isResolvableHostname: Bool = true) {
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
    }

    /// Force-flush pending entries to disk (async)
    func flush() {
        queue.async { [weak self] in
            self?._flushPending()
        }
    }

    /// Synchronously flush pending entries. Call before reading entries for upload.
    func flushSync() {
        queue.sync { [weak self] in
            self?._flushPending()
        }
    }

    /// Must be called on `queue`.
    private func _flushPending() {
        guard !pendingEntries.isEmpty else { return }
        let toWrite = pendingEntries
        pendingEntries = []
        lastFlush = Date()
        writeEntries(toWrite)
    }

    private func writeEntries(_ newEntries: [ActivityLogEntry]) {
        guard let defaults = sharedDefaults else {
            os_log("IOSActivityLogger.writeEntries: sharedDefaults is nil!", log: writeLogger, type: .error)
            return
        }
        defaults.synchronize()

        var existing: [ActivityLogEntry] = []
        if let data = defaults.data(forKey: logKey) {
            existing = (try? JSONDecoder().decode([ActivityLogEntry].self, from: data)) ?? []
        }

        // Prepend new entries and trim to max, ensuring fair per-app representation
        existing = newEntries + existing
        if existing.count > maxEntries {
            // Keep at most 50 entries per app to prevent one noisy app from pushing others out
            let maxPerApp = 50
            var counts: [String: Int] = [:]
            existing = existing.filter { entry in
                let key = entry.sourceApp?.lowercased() ?? "__nil__"
                let count = counts[key, default: 0]
                counts[key] = count + 1
                return count < maxPerApp
            }
            if existing.count > maxEntries {
                existing = Array(existing.prefix(maxEntries))
            }
        }

        if let data = try? JSONEncoder().encode(existing) {
            defaults.set(data, forKey: logKey)
            defaults.synchronize()
        }
    }

    // MARK: - Reading

    /// Read the activity log (called from the iOS app)
    func loadEntries() -> [ActivityLogEntry] {
        guard let defaults = sharedDefaults else { return [] }
        defaults.synchronize()
        guard let data = defaults.data(forKey: logKey) else { return [] }
        return (try? JSONDecoder().decode([ActivityLogEntry].self, from: data)) ?? []
    }

    /// Clear all log entries
    func clearLog() {
        sharedDefaults?.removeObject(forKey: logKey)
        sharedDefaults?.synchronize()
    }
}
