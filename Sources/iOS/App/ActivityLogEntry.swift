//
//  ActivityLogEntry.swift
//  GetBored
//
//  Created by Tushar on 26.02.26.
//

import Foundation
import Darwin

/// A single filter decision logged by the extension.
/// Every time a network request is blocked or allowed, one of these gets created.
struct ActivityLogEntry: Identifiable, Codable {
    /// Unique identifier for this log entry
    let id: UUID

    /// The hostname shown to the user (e.g. "instagram.com")
    let displayDomain: String

    /// The raw endpoint before hostname resolution (could be an IP address like "157.240.1.35")
    let rawEndpoint: String?

    /// How the hostname was determined: "url", "sni", "http-host", or "legacy"
    let resolutionSource: String

    /// False if the endpoint is an IP address rather than a resolvable hostname
    let isResolvableHostname: Bool

    /// True = request was blocked, false = request was allowed
    let blocked: Bool

    /// Human-readable reason (e.g. "Blocked by blocklist", "Allowed: Apple system domain")
    let reason: String

    /// Bundle ID of the app that made the request (e.g. "com.apple.mobilesafari")
    let sourceApp: String?

    /// When this filter decision was made
    let timestamp: Date

    // MARK: - Coding Keys

    /// Custom keys to support legacy "domain" field migration
    private enum CodingKeys: String, CodingKey {
        case id
        case domain
        case displayDomain
        case rawEndpoint
        case resolutionSource
        case isResolvableHostname
        case blocked
        case reason
        case sourceApp
        case timestamp
    }

    // MARK: - Initializers

    init(displayDomain: String,
         blocked: Bool,
         reason: String,
         sourceApp: String? = nil,
         timestamp: Date = Date(),
         rawEndpoint: String? = nil,
         resolutionSource: String = "legacy",
         isResolvableHostname: Bool = true) {
        self.id = UUID()
        self.displayDomain = displayDomain
        self.rawEndpoint = rawEndpoint
        self.resolutionSource = resolutionSource
        self.isResolvableHostname = isResolvableHostname
        self.blocked = blocked
        self.reason = reason
        self.sourceApp = sourceApp
        self.timestamp = timestamp
    }

    /// Legacy initializer for older code that used "domain" instead of "displayDomain"
    init(domain: String, blocked: Bool, reason: String, sourceApp: String? = nil, timestamp: Date = Date()) {
        self.init(
            displayDomain: domain,
            blocked: blocked,
            reason: reason,
            sourceApp: sourceApp,
            timestamp: timestamp,
            rawEndpoint: nil,
            resolutionSource: "legacy",
            isResolvableHostname: !Self.looksLikeIPAddress(domain)
        )
    }

    /// Custom decoder that handles both old ("domain") and new ("displayDomain") JSON keys
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        blocked = try container.decodeIfPresent(Bool.self, forKey: .blocked) ?? true
        reason = try container.decodeIfPresent(String.self, forKey: .reason) ?? "Blocked by filter"
        sourceApp = try container.decodeIfPresent(String.self, forKey: .sourceApp)
        timestamp = try container.decodeIfPresent(Date.self, forKey: .timestamp) ?? Date()

        // Try new key first, fall back to legacy "domain" key
        let legacyDomain = try container.decodeIfPresent(String.self, forKey: .domain)
        displayDomain = try container.decodeIfPresent(String.self, forKey: .displayDomain)
            ?? legacyDomain
            ?? "unknown-host"
        rawEndpoint = try container.decodeIfPresent(String.self, forKey: .rawEndpoint)
        resolutionSource = try container.decodeIfPresent(String.self, forKey: .resolutionSource) ?? "legacy"
        isResolvableHostname = try container.decodeIfPresent(Bool.self, forKey: .isResolvableHostname)
            ?? !Self.looksLikeIPAddress(displayDomain)
    }

    /// Custom encoder that writes both "displayDomain" and legacy "domain" for backwards compatibility
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(displayDomain, forKey: .displayDomain)
        try container.encode(displayDomain, forKey: .domain)
        try container.encodeIfPresent(rawEndpoint, forKey: .rawEndpoint)
        try container.encode(resolutionSource, forKey: .resolutionSource)
        try container.encode(isResolvableHostname, forKey: .isResolvableHostname)
        try container.encode(blocked, forKey: .blocked)
        try container.encode(reason, forKey: .reason)
        try container.encodeIfPresent(sourceApp, forKey: .sourceApp)
        try container.encode(timestamp, forKey: .timestamp)
    }

    // MARK: - Computed Properties

    /// Alias for displayDomain (backwards compatibility)
    var domain: String { displayDomain }

    /// "BLOCKED" or "ALLOWED" for display
    var verdictText: String { blocked ? "BLOCKED" : "ALLOWED" }

    /// Human-readable relative time (e.g. "5s ago", "3m ago", "2h ago")
    var relativeTime: String {
        let interval = Date().timeIntervalSince(timestamp)
        if interval < 60 { return "\(Int(interval))s ago" }
        if interval < 3600 { return "\(Int(interval / 60))m ago" }
        return "\(Int(interval / 3600))h ago"
    }

    // MARK: - Helpers

    /// Detects if a string is an IPv4 or IPv6 address using C inet_pton
    private static func looksLikeIPAddress(_ host: String) -> Bool {
        let normalized = host.trimmingCharacters(in: CharacterSet(charactersIn: "[] .")).lowercased()
        if normalized.isEmpty { return false }
        var ipv4 = in_addr()
        if normalized.withCString({ inet_pton(AF_INET, $0, &ipv4) }) == 1 { return true }
        var ipv6 = in6_addr()
        if normalized.withCString({ inet_pton(AF_INET6, $0, &ipv6) }) == 1 { return true }
        return false
    }
}
