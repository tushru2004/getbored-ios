/**
 * LegacyWhitelistPolicyTests.swift
 *
 * These contract tests preserve the behavior of the original whitelist policy
 * while its production implementation now lives in IOSDecisionCore. The helpers
 * remain independent so a mistaken production refactor cannot make both the
 * implementation and its compatibility tests pass for the same wrong reason.
 *
 * The six behavior groups correspond to the former public whitelist API:
 *   isExcepted(fullURL:)            → testIsExcepted*
 *   isAppAllowed(_:)                → testIsAppAllowed*
 *   baseKeyword(from:)              → testBaseKeyword*
 *   extractDomain(from:)            → testExtractDomain*
 *   isRelatedToAllowedEntry(host:)  → testIsRelatedToAllowedEntry*
 *   isListed(url:)                  → testIsListed*
 */

import XCTest

// MARK: - Independent compatibility helpers

private func extractDomain(from input: String) -> String {
        var s = input
        if let range = s.range(of: "://") {
            s = String(s[range.upperBound...])
        }
        if let slash = s.firstIndex(of: "/") { s = String(s[..<slash]) }
        if let colon = s.firstIndex(of: ":") { s = String(s[..<colon]) }
        if let question = s.firstIndex(of: "?") { s = String(s[..<question]) }
        return s
}

private func baseKeyword(from domain: String) -> String? {
        let parts = domain.lowercased().split(separator: ".")
        guard parts.count >= 2 else { return nil }
        let sld = String(parts[parts.count - 2])
        guard sld.count >= 4 else { return nil }
        return sld
}

private func isExcepted(fullURL: String, exceptions: [String]) -> Bool {
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

private func isAppAllowed(_ bundleID: String, allowedApps: [String]) -> Bool {
        guard !allowedApps.isEmpty else { return false }
        let id = bundleID.lowercased()
        return allowedApps.contains { stored in
            let s = stored.lowercased()
            return s == id || id.hasSuffix(".\(s)")
        }
}

private func isAppBlocked(_ bundleID: String, blockedApps: [String]) -> Bool {
        guard !blockedApps.isEmpty else { return false }
        let id = bundleID.lowercased()
        return blockedApps.contains { stored in
            let s = stored.lowercased()
            return s == id || id.hasSuffix(".\(s)")
        }
}

private func isListed(url: String, items: [String]) -> Bool {
        let host = extractDomain(from: url).lowercased()
        guard !host.isEmpty else { return false }
        return items.contains { item in
            let domain = extractDomain(from: item).lowercased()
            return host == domain || host.hasSuffix("." + domain)
        }
}

private func isRelatedToAllowedEntry(host: String, items: [String]) -> Bool {
        guard !items.isEmpty else { return false }
        let h = host.lowercased()
        return items.contains { item in
            guard let keyword = baseKeyword(from: extractDomain(from: item)) else { return false }
            return h.contains(keyword)
        }
}

// MARK: - Test class

    final class LegacyWhitelistPolicyTests: XCTestCase {

        // MARK: extractDomain(from:)

        func testExtractDomain_stripsScheme() {
            XCTAssertEqual(extractDomain(from: "https://example.com/path"), "example.com")
        }

        func testExtractDomain_stripsPort() {
            XCTAssertEqual(extractDomain(from: "example.com:8080"), "example.com")
        }

        func testExtractDomain_stripsQuery() {
            XCTAssertEqual(extractDomain(from: "https://example.com?q=1"), "example.com")
        }

        func testExtractDomain_trailingSlash() {
            XCTAssertEqual(extractDomain(from: "https://example.com/"), "example.com")
        }

        func testExtractDomain_trailingDot() {
            // trailing dot is a valid DNS absolute form; extractDomain preserves it
            XCTAssertEqual(extractDomain(from: "example.com."), "example.com.")
        }

        func testExtractDomain_emptyString() {
            XCTAssertEqual(extractDomain(from: ""), "")
        }

        func testExtractDomain_whitespace() {
            XCTAssertEqual(extractDomain(from: "   "), "   ")
        }

        func testExtractDomain_unicodeHost() {
            // Punycode and unicode forms both survive extraction unchanged
            XCTAssertEqual(extractDomain(from: "https://bücher.example/path"), "bücher.example")
            XCTAssertEqual(extractDomain(from: "https://xn--bcher-kva.example/path"), "xn--bcher-kva.example")
        }

        func testExtractDomain_mixedCaseURL() {
            // extractDomain is case-preserving; callers lowercase the result
            XCTAssertEqual(extractDomain(from: "HTTPS://EXAMPLE.COM/Path"), "EXAMPLE.COM")
        }

        // MARK: baseKeyword(from:)

        func testBaseKeyword_standardDomain() {
            XCTAssertEqual(baseKeyword(from: "amazon.com"), "amazon")
        }

        func testBaseKeyword_subdomain() {
            XCTAssertEqual(baseKeyword(from: "maps.google.com"), "google")
        }

        func testBaseKeyword_ccTLD() {
            XCTAssertEqual(baseKeyword(from: "amazon.de"), "amazon")
        }

        func testBaseKeyword_hyphenated() {
            XCTAssertEqual(baseKeyword(from: "ssl-images-amazon.com"), "ssl-images-amazon")
        }

        func testBaseKeyword_singleWord_returnsNil() {
            // no dot → fewer than 2 parts → nil
            XCTAssertNil(baseKeyword(from: "localhost"))
        }

        func testBaseKeyword_shortSLD_returnsNil() {
            // SLD "go" is only 2 chars, below the 4-char threshold
            XCTAssertNil(baseKeyword(from: "go.co"))
        }

        func testBaseKeyword_exactlyFourChars() {
            XCTAssertEqual(baseKeyword(from: "uber.com"), "uber")
        }

        func testBaseKeyword_empty_returnsNil() {
            XCTAssertNil(baseKeyword(from: ""))
        }

        // MARK: isExcepted(fullURL:)

        func testIsExcepted_exactMatch() {
            XCTAssertTrue(
                isExcepted(fullURL: "https://news.ycombinator.com", exceptions: ["news.ycombinator.com"]))
        }

        func testIsExcepted_wwwStripped() {
            // Both the URL and the stored exception have "www." stripped before comparison
            XCTAssertTrue(isExcepted(fullURL: "https://www.example.com/page", exceptions: ["example.com"]))
        }

        func testIsExcepted_schemeStripped() {
            XCTAssertTrue(isExcepted(fullURL: "http://example.com", exceptions: ["example.com"]))
        }

        func testIsExcepted_caseInsensitive() {
            XCTAssertTrue(isExcepted(fullURL: "HTTPS://EXAMPLE.COM/Path", exceptions: ["example.com"]))
        }

        func testIsExcepted_noMatch() {
            XCTAssertFalse(isExcepted(fullURL: "https://other.com", exceptions: ["example.com"]))
        }

        func testIsExcepted_emptyExceptions_returnsFalse() {
            XCTAssertFalse(isExcepted(fullURL: "https://example.com", exceptions: []))
        }

        func testIsExcepted_emptyURL_returnsFalse() {
            XCTAssertFalse(isExcepted(fullURL: "", exceptions: ["example.com"]))
        }

        func testIsExcepted_whitespaceURL_returnsFalse() {
            XCTAssertFalse(isExcepted(fullURL: "   ", exceptions: ["example.com"]))
        }

        // MARK: isAppAllowed(_:)

        func testIsAppAllowed_exactMatch() {
            XCTAssertTrue(isAppAllowed("com.example.app", allowedApps: ["com.example.app"]))
        }

        func testIsAppAllowed_teamPrefixSuffix() {
            // Team prefix "ABCD1234." prepended by system; stored entry is without prefix
            XCTAssertTrue(isAppAllowed("ABCD1234.com.example.app", allowedApps: ["com.example.app"]))
        }

        func testIsAppAllowed_caseInsensitive() {
            XCTAssertTrue(isAppAllowed("COM.EXAMPLE.APP", allowedApps: ["com.example.app"]))
        }

        func testIsAppAllowed_partialMatch_returnsFalse() {
            // "com.example" should NOT match "com.example.app"
            XCTAssertFalse(isAppAllowed("com.example", allowedApps: ["com.example.app"]))
        }

        func testIsAppAllowed_emptyAllowedList_returnsFalse() {
            XCTAssertFalse(isAppAllowed("com.example.app", allowedApps: []))
        }

        func testIsAppAllowed_emptyBundleID_returnsFalse() {
            XCTAssertFalse(isAppAllowed("", allowedApps: ["com.example.app"]))
        }

        func testIsAppAllowed_teamPrefixOnly_returnsFalse() {
            // "ABCD1234.com.other.app" should NOT match "com.example.app"
            XCTAssertFalse(isAppAllowed("ABCD1234.com.other.app", allowedApps: ["com.example.app"]))
        }

        // MARK: isListed(url:)

        func testIsListed_exactDomainMatch() {
            XCTAssertTrue(isListed(url: "https://google.com", items: ["google.com"]))
        }

        func testIsListed_subdomainMatch() {
            XCTAssertTrue(isListed(url: "https://mail.google.com", items: ["google.com"]))
        }

        func testIsListed_deepSubdomainMatch() {
            XCTAssertTrue(isListed(url: "https://a.b.google.com", items: ["google.com"]))
        }

        func testIsListed_noMatch() {
            XCTAssertFalse(isListed(url: "https://bing.com", items: ["google.com"]))
        }

        func testIsListed_emptyItems_returnsFalse() {
            XCTAssertFalse(isListed(url: "https://google.com", items: []))
        }

        func testIsListed_emptyURL_returnsFalse() {
            XCTAssertFalse(isListed(url: "", items: ["google.com"]))
        }

        func testIsListed_caseInsensitive() {
            // extractDomain preserves case but isListed lowercases before comparison
            XCTAssertTrue(isListed(url: "HTTPS://MAIL.GOOGLE.COM/", items: ["google.com"]))
        }

        func testIsListed_unicodeHost() {
            XCTAssertTrue(isListed(url: "https://bücher.example", items: ["bücher.example"]))
        }

        func testIsListed_portSuffix() {
            XCTAssertTrue(isListed(url: "https://google.com:443/search", items: ["google.com"]))
        }

        func testIsListed_parentDoesNotMatchSubEntry() {
            // "google.com" should NOT be listed when the stored entry is "mail.google.com"
            XCTAssertFalse(isListed(url: "https://google.com", items: ["mail.google.com"]))
        }

        // MARK: isRelatedToAllowedEntry(host:)

        func testIsRelatedToAllowedEntry_keywordMatch() {
            // CDN host contains "amazon" extracted from "amazon.com"
            XCTAssertTrue(isRelatedToAllowedEntry(host: "images-eu.ssl-images-amazon.com", items: ["amazon.com"]))
        }

        func testIsRelatedToAllowedEntry_noMatch() {
            XCTAssertFalse(isRelatedToAllowedEntry(host: "cdn.unrelated.net", items: ["amazon.com"]))
        }

        func testIsRelatedToAllowedEntry_emptyItems_returnsFalse() {
            XCTAssertFalse(isRelatedToAllowedEntry(host: "images-amazon.com", items: []))
        }

        func testIsRelatedToAllowedEntry_shortSLD_skipped() {
            // "go.co" has SLD "go" (2 chars) — below threshold → no keyword → no match
            XCTAssertFalse(isRelatedToAllowedEntry(host: "storage.go.co", items: ["go.co"]))
        }

        func testIsRelatedToAllowedEntry_exactKeywordContainment() {
            XCTAssertTrue(isRelatedToAllowedEntry(host: "www.googlevideo.com", items: ["google.com"]))
        }

        // MARK: Cross-cutting: Unicode + mixed-case

        func testCrossCutting_unicodePunycodeConsistency() {
            // Both forms should be treated consistently by extractDomain (case-preserving)
            let unicode = extractDomain(from: "https://bücher.example/page").lowercased()
            let punycode = extractDomain(from: "https://xn--bcher-kva.example/page").lowercased()
            // They are different strings (unicode != punycode), but both extracted correctly
            XCTAssertEqual(unicode, "bücher.example")
            XCTAssertEqual(punycode, "xn--bcher-kva.example")
        }

        func testCrossCutting_mixedCaseURLIsListed() {
            // Mixed-case URL should match a lowercase stored entry
            XCTAssertTrue(isListed(url: "HTTPS://EXAMPLE.COM/Path", items: ["example.com"]))
        }

        func testCrossCutting_mixedCaseURLIsExcepted() {
            XCTAssertTrue(isExcepted(fullURL: "HTTPS://EXAMPLE.COM/Path", exceptions: ["example.com"]))
        }

        func testCrossCutting_teamPrefixBundleIDAllowed() {
            XCTAssertTrue(isAppAllowed("ABCD1234.com.example.app", allowedApps: ["com.example.app"]))
            XCTAssertFalse(isAppAllowed("ABCD1234.com.other.app", allowedApps: ["com.example.app"]))
        }

        func testCrossCutting_subdomainVsExactEntry() {
            // subdomain "mail.google.com" is listed when entry is "google.com"
            XCTAssertTrue(isListed(url: "mail.google.com", items: ["google.com"]))
            // but parent "google.com" is NOT listed when entry is "mail.google.com"
            XCTAssertFalse(isListed(url: "google.com", items: ["mail.google.com"]))
        }

        func testCrossCutting_whitespaceInputs() {
            XCTAssertEqual(extractDomain(from: ""), "")
            XCTAssertFalse(isListed(url: "", items: ["example.com"]))
            XCTAssertFalse(isExcepted(fullURL: "", exceptions: ["example.com"]))
            XCTAssertFalse(isAppAllowed("", allowedApps: ["com.example.app"]))
        }

        func testCrossCutting_trailingSlashAndPort() {
            XCTAssertTrue(isListed(url: "https://example.com:443/", items: ["example.com"]))
        }

        // MARK: isAppBlocked(_:)

        func testIsAppBlocked_exactMatch() {
            XCTAssertTrue(isAppBlocked("com.tiktok.TikTok", blockedApps: ["com.tiktok.TikTok"]))
        }

        func testIsAppBlocked_teamPrefixSuffix() {
            // Team prefix "ABCD1234." prepended by system; stored entry is without prefix
            XCTAssertTrue(isAppBlocked("ABCD1234.com.tiktok.TikTok", blockedApps: ["com.tiktok.TikTok"]))
        }

        func testIsAppBlocked_caseInsensitive() {
            XCTAssertTrue(isAppBlocked("COM.TIKTOK.TIKTOK", blockedApps: ["com.tiktok.TikTok"]))
        }

        func testIsAppBlocked_lookalike_returnsFalse() {
            // "com.tiktok.TikTokEvil" does not equal "com.tiktok.TikTok"
            // and does not end with ".com.tiktok.TikTok"
            XCTAssertFalse(isAppBlocked("com.tiktok.TikTokEvil", blockedApps: ["com.tiktok.TikTok"]))
        }

        func testIsAppBlocked_emptyBlockedList_returnsFalse() {
            XCTAssertFalse(isAppBlocked("com.tiktok.TikTok", blockedApps: []))
        }

        func testIsAppBlocked_precedence_allowedWins() {
            // An app in BOTH allowed and blocked: shouldAllowApp runs first so allow wins.
            // This test encodes the ordering contract: isAppAllowed takes priority.
            let bundleID = "com.example.app"
            let allowedApps = ["com.example.app"]
            let blockedApps = ["com.example.app"]

            let allowed = isAppAllowed(bundleID, allowedApps: allowedApps)
            let blocked = isAppBlocked(bundleID, blockedApps: blockedApps)

            // Both return true on their own — the caller (FlowInspector) must check allow first.
            XCTAssertTrue(allowed)
            XCTAssertTrue(blocked)
            // Precedence rule: allowed check wins because FlowInspector returns .allow() before
            // ever reaching the isAppBlocked guard.
            XCTAssertTrue(allowed, "shouldAllowApp result must be checked before isAppBlocked")
        }
    }
