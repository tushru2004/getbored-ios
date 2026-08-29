import Foundation
import GetBoredCore
import XCTest

@testable import GetBoredIOSCore

/// Protects the behavior migrated from the former Kotlin shared decision core.
///
/// These tests exercise the public Swift policy surface directly so native
/// providers and the React Native bridge continue to receive compatible results.
final class IOSDecisionCoreParityTests: XCTestCase {
				private func rules(
								sites: [String] = [],
								mode: FilterMode = .blockSpecific,
								exceptions: [String] = [],
								allowedApps: [String] = [],
								blockedApps: [String] = []
				) -> LoadedFilterRules {
								LoadedFilterRules(
												siteRules: sites.map { SiteRule(url: $0, title: $0) },
												filterMode: mode,
												exceptions: exceptions,
												allowedAppBundleIDs: allowedApps,
												blockedAppBundleIDs: blockedApps
								)
				}

				func testFilterStatusLabelsMatchLegacyPolicy() {
								let checking = IOSDecisionCore.filterStatusViewModel(
												filterEnabled: nil,
												filterErrorMessage: nil,
												icloudAvailable: nil,
												icloudErrorMessage: nil
								)
								XCTAssertEqual(
												checking.toDictionary(),
												[
																"filterState": "checking",
																"filterLabel": "Checking...",
																"icloudState": "checking",
																"icloudLabel": "Checking...",
												])

								let active = IOSDecisionCore.filterStatusViewModel(
												filterEnabled: true,
												filterErrorMessage: nil,
												icloudAvailable: true,
												icloudErrorMessage: nil
								)
								XCTAssertEqual(active.filterState, "active")
								XCTAssertEqual(active.filterLabel, "Active & Protecting")
								XCTAssertEqual(active.icloudState, "available")
								XCTAssertEqual(active.icloudLabel, "Connected")

								let errors = IOSDecisionCore.filterStatusViewModel(
												filterEnabled: false,
												filterErrorMessage: "Provider unavailable",
												icloudAvailable: false,
												icloudErrorMessage: "No iCloud account"
								)
								XCTAssertEqual(errors.filterState, "error")
								XCTAssertEqual(errors.filterLabel, "Provider unavailable")
								XCTAssertEqual(errors.icloudState, "unavailable")
								XCTAssertEqual(errors.icloudLabel, "No iCloud account")
				}

				func testHostNormalizationAndDomainMatchingMatchLegacyPolicy() {
								XCTAssertEqual(
												IOSDecisionCore.normalizeHost(" HTTPS://WWW.Example.COM:443/a?b "), "www.example.com")
								XCTAssertEqual(
												IOSDecisionCore.normalizeChildPattern(" *.CDN.Example.com. "), "*.cdn.example.com")
								XCTAssertTrue(
												IOSDecisionCore.hostMatchesDomain("api.example.com", domain: "example.com"))
								XCTAssertFalse(
												IOSDecisionCore.hostMatchesDomain("example.com.evil", domain: "example.com"))
								XCTAssertTrue(
												IOSDecisionCore.hostMatchesChildPattern(
																"cdn.example.com", childPattern: "*.example.com"))
								XCTAssertTrue(
												IOSDecisionCore.hostMatchesChildPattern("example.com", childPattern: "*.example.com"))
								XCTAssertEqual(IOSDecisionCore.baseKeyword("https://www.youtube.com/watch"), "youtube")
								XCTAssertTrue(
												IOSDecisionCore.hostContainsAnyRelatedKeyword(
																"img.youtubecdn.com", domains: ["youtube.com"]))
				}

				func testBlockAndExceptionPolicyPreserveLegacyPrefixBehavior() {
								let blockRules = rules(sites: ["youtube.com"], exceptions: ["youtube.com/watch"])
								XCTAssertTrue(
												IOSDecisionCore.shouldBlock("https://m.youtube.com/feed", using: blockRules))
								XCTAssertFalse(
												IOSDecisionCore.shouldBlock("https://youtube.com/watch?v=1", using: blockRules))
								// The legacy policy treats exceptions as a raw prefix, not a path-boundary match.
								XCTAssertFalse(IOSDecisionCore.shouldBlock("youtube.com/watching", using: blockRules))

								let allowRules = rules(sites: ["school.example"], mode: .whiteList)
								XCTAssertFalse(IOSDecisionCore.shouldBlock("sub.school.example", using: allowRules))
								XCTAssertTrue(IOSDecisionCore.shouldBlock("other.example", using: allowRules))
				}

				func testHostClassificationReasonStringsMatchLegacyPolicy() {
								let whitelist = rules(sites: ["school.example"], mode: .whiteList)
								let allowed = IOSDecisionCore.classifyHost(
												"school.example", using: whitelist, systemAllowedSuffixes: [], allowedSafariParent: nil
								)
								XCTAssertEqual(allowed.kind, .allow)
								XCTAssertEqual(allowed.reason, "In allowed list")

								let child = IOSDecisionCore.classifyHost(
												"cdn.example", using: whitelist, systemAllowedSuffixes: [],
												allowedSafariParent: "school.example"
								)
								XCTAssertEqual(child.kind, .allow)
								XCTAssertEqual(child.reason, "Child of allowed Safari parent school.example")

								let blocked = IOSDecisionCore.classifyHost(
												"other.example", using: whitelist, systemAllowedSuffixes: [], allowedSafariParent: nil
								)
								XCTAssertEqual(blocked.kind, .block)
								XCTAssertEqual(blocked.reason, "Block everything mode")

								let emptyBlocklist = IOSDecisionCore.classifyHost(
												"other.example", using: rules(), systemAllowedSuffixes: [], allowedSafariParent: nil
								)
								XCTAssertEqual(emptyBlocklist.kind, .allow)
								XCTAssertEqual(emptyBlocklist.reason, "Empty blocklist")
								XCTAssertTrue(
												IOSDecisionCore.isSystemAllowed(
																"configuration.apple.com", systemAllowedSuffixes: ["apple.com"]))
				}

				func testAppPoliciesAndActivityIdentifierPolicyMatchLegacyBehavior() {
								let rules = rules(
												mode: .whiteList,
												allowedApps: ["com.good.app"],
												blockedApps: ["com.bad.app"]
								)
								XCTAssertTrue(IOSDecisionCore.matchesAllowedApp("TEAM.com.good.app", using: rules))
								XCTAssertTrue(IOSDecisionCore.shouldAllowApp("TEAM.com.apple.Preferences", using: rules))
								XCTAssertFalse(
												IOSDecisionCore.shouldAllowApp("TEAM.com.apple.mobilesafari", using: rules))
								XCTAssertTrue(IOSDecisionCore.isAppBlocked("TEAM.com.bad.app", using: rules))
								XCTAssertTrue(IOSDecisionCore.shouldLogBlockedAppProbe("com.unknown.app", using: rules))
								XCTAssertFalse(IOSDecisionCore.shouldLogBlockedAppProbe(nil, using: rules))

								XCTAssertEqual(
												IOSDecisionCore.activityLogStripTeamID("TEAM1234.com.example.app"), "com.example.app")
								XCTAssertEqual(
												IOSDecisionCore.activityLogStripTeamID("prefix.org.example.app"), "org.example.app")
								XCTAssertEqual(
												IOSDecisionCore.activityLogStripTeamID("foo.org.example.com.app"), "com.app")
								XCTAssertEqual(
												IOSDecisionCore.activityLogStripTeamID("plain.identifier"), "plain.identifier")
								XCTAssertNil(IOSDecisionCore.activityLogStripTeamID(""))
				}

				func testNetworkPayloadParsersAndBlockedHostResolutionMatchLegacyBehavior() {
								let request = Data("CONNECT /video HTTP/1.1\r\nHost: video.example:443\r\n\r\n".utf8)
								XCTAssertEqual(IOSDecisionCore.extractHTTPHost(from: request), "video.example")
								XCTAssertEqual(IOSDecisionCore.extractHTTPFullURL(from: request), "video.example/video")
								XCTAssertNil(IOSDecisionCore.extractSNI(from: Data([0x16, 0, 0, 0, 0, 0x01])))
								XCTAssertEqual(IOSDecisionCore.extractSNI(from: clientHello(serverName: Array("abc".utf8))), "abc")
								XCTAssertEqual(IOSDecisionCore.extractSNI(from: clientHello(serverName: [0xff])), "\u{fffd}")
								XCTAssertEqual(
												IOSDecisionCore.extractSNI(
																from: clientHello(serverName: Array("abc".utf8), advertisedExtensionLength: 0xffff)),
												"abc")

								let urlHost = IOSDecisionCore.resolveBlockedHost(
												rawURLHost: "https://Video.Example/path", rawEndpoint: "10.0.0.1:443",
												sourceApp: "com.example"
								)
								XCTAssertEqual(urlHost.displayDomain, "video.example")
								XCTAssertEqual(urlHost.rawEndpoint, "10.0.0.1")
								XCTAssertEqual(urlHost.resolutionSource, "url-host")

								let socketHost = IOSDecisionCore.resolveBlockedHost(
												rawURLHost: "unknown", rawEndpoint: "cdn.example:443", sourceApp: nil
								)
								XCTAssertEqual(socketHost.displayDomain, "cdn.example")
								XCTAssertEqual(socketHost.resolutionSource, "socket-endpoint")

								let fallback = IOSDecisionCore.resolveBlockedHost(
												rawURLHost: nil, rawEndpoint: "192.0.2.1:443", sourceApp: "com.example.app"
								)
								XCTAssertEqual(fallback.displayDomain, "app:com.example.app")
								XCTAssertEqual(fallback.resolutionSource, "source-app-fallback")
								XCTAssertFalse(fallback.isResolvableHostname)
				}

				private func clientHello(
								serverName: [UInt8], advertisedExtensionLength: Int? = nil
				) -> Data {
								var bytes = Array(repeating: UInt8(0), count: 43)
								bytes[0] = 0x16
								bytes[5] = 0x01
								bytes.append(0)  // Session ID length.
								bytes.append(contentsOf: [0, 0])  // Cipher suites length.
								bytes.append(0)  // Compression methods length.
								let extensionPayloadLength = 5 + serverName.count
								let extensionsLength = 4 + extensionPayloadLength
								bytes.append(contentsOf: [UInt8(extensionsLength >> 8), UInt8(extensionsLength & 0xff)])
								bytes.append(contentsOf: [0, 0])  // SNI extension type.
								let encodedExtensionLength = advertisedExtensionLength ?? extensionPayloadLength
								bytes.append(contentsOf: [
												UInt8(encodedExtensionLength >> 8), UInt8(encodedExtensionLength & 0xff),
												UInt8((serverName.count + 3) >> 8), UInt8((serverName.count + 3) & 0xff),
												0, UInt8(serverName.count >> 8), UInt8(serverName.count & 0xff),
								])
								bytes.append(contentsOf: serverName)
								return Data(bytes)
				}

				func testParentChildPersistenceAndAllowDecisionMatchLegacyBehavior() {
								let context = IOSDecisionCore.normalizedActivePageContext(
												parentDomain: "School.Example",
												childDomains: ["CDN.School.Example", "*.assets.school.example", "school.example"],
												url: "https://school.example/home",
												receivedAtSwiftRefSeconds: 100
								)
								XCTAssertEqual(context?.parentDomain, "school.example")
								XCTAssertEqual(context?.childDomains, ["*.assets.school.example", "cdn.school.example"])

								let registry = IOSDecisionCore.parentChildUpdatedRegistryJSON(
												registryJson: nil,
												parentDomain: "school.example",
												childDomains: ["cdn.school.example", "cdn.school.example"]
								)
								XCTAssertEqual(registry, "{\"school.example\":[\"cdn.school.example\"]}")

								let contextJSON =
												"{\"parentDomain\":\"school.example\",\"childDomains\":[\"*.assets.school.example\"],\"url\":\"https://school.example\",\"receivedAt\":100}"
								let observationJSON =
												"{\"requestHost\":\"cdn.assets.school.example\",\"parentDomain\":\"school.example\",\"decision\":\"matchActiveChild\",\"endpoint\":\"cdn.assets.school.example:443\",\"observedAt\":105}"
								let decision = IOSDecisionCore.allowedSafariParentForChild(
												flowObservationJson: observationJSON,
												activeContextJson: contextJSON,
												parentChildMapJson: nil,
												registryJson: registry,
												requestHost: "cdn.assets.school.example",
												maxAgeSeconds: 60,
												nowEpochSeconds: 110,
												using: rules(sites: ["school.example"], mode: .whiteList)
								)
								XCTAssertEqual(decision?.shouldAllow, true)
								XCTAssertEqual(
												decision?.event,
												"DATA_PROVIDER_ALLOW_CHILD host=cdn.assets.school.example parent=school.example age=5.0")
								XCTAssertTrue(
												IOSDecisionCore.shouldClearActiveContext(
																activeContextJson: contextJSON, clearingParent: "school.example"))
								XCTAssertFalse(
												IOSDecisionCore.shouldClearActiveContext(
																activeContextJson: contextJSON, clearingParent: "another.example"))
								XCTAssertEqual(
												IOSDecisionCore.parentChildAppendEvent(
																existingEvents: ["old"], timestamp: "t", event: "new", maxEvents: 1
												),
												["t new"]
								)

								XCTAssertEqual(
												IOSDecisionCore.parentChildMergedChildren(
																parentChildMapJson:
																				"{\"schemaVersion\":1,\"rules\":[{\"p\":\"school.example\",\"c\":[\"static.school.example\"]}]}",
																activeContextJson: nil,
																registryJson: registry,
																parentDomain: "school.example"
												),
												Set(["static.school.example"])
								)
								XCTAssertTrue(
												IOSDecisionCore.isValidParentChildMapJSON(
																"{\"schemaVersion\":1,\"rules\":[{\"p\":\"school.example\",\"c\":[\"cdn.school.example\"]}]}"
												))
								XCTAssertFalse(IOSDecisionCore.isValidParentChildMapJSON("not json"))
								let legacyPayload = IOSDecisionCore.parentChildLegacyPayload(
												parentDomain: "school.example", childDomains: ["cdn.school.example"],
												url: "https://school.example",
												receivedAtSwiftRefSeconds: 100
								)
								XCTAssertEqual(legacyPayload["type"] as? String, "getbored.childRegistrationProbe")
								XCTAssertEqual(legacyPayload["source"] as? String, "safari-extension")
								XCTAssertEqual(legacyPayload["receivedAt"] as? String, "2001-01-01T00:01:40Z")
								XCTAssertEqual(
												IOSDecisionCore.normalizedFlowObservation(
																requestHost: "CDN.school.example", parentDomain: "School.example",
																decision: "matchActiveChild",
																endpoint: "cdn.school.example:443", observedAtSwiftRefSeconds: 101
												)?.requestHost,
												"cdn.school.example"
								)
				}

				func testSafariRelayAndActivityLogTrimMatchLegacyBehavior() {
								// The explicitly allowed page is narrower than the active parent, so the
								// child route exercises the Safari parent/child fallback rather than a
								// normal domain-list direct allow.
								let whitelist = rules(sites: ["www.school-page.example"], mode: .whiteList)
								let relay = IOSDecisionCore.safariRelayDecision(
												endpoint: "cdn.assets.school.example:443",
												using: whitelist,
												systemAllowedSuffixes: [],
												activeParent: "school-page.example",
												activeChildren: ["*.assets.school.example"],
												activeContextAge: 5,
												activeContextMaxAge: 60,
												activeContextRefreshMinAge: 30
								)
								XCTAssertTrue(relay.shouldRelay)
								XCTAssertEqual(relay.parentChildKind, .matchActiveChild)
								XCTAssertEqual(
												relay.primaryEvent,
												"ALLOW_CHILD host=cdn.assets.school.example parent=school-page.example age=5.0"
								)
								XCTAssertEqual(
												relay.outcomeEvent,
												"APP_PROXY_ALLOW_ACTIVE_CHILD host=cdn.assets.school.example parent=school-page.example endpoint=cdn.assets.school.example:443"
								)
								XCTAssertTrue(relay.shouldSaveFlowObservation)

								let newEntries = (0..<3).map { index in
												ActivityLogEntry(
																displayDomain: "new\(index).example", blocked: true, reason: "test",
																sourceApp: "com.example")
								}
								let existing = (0..<3).map { index in
												ActivityLogEntry(
																displayDomain: "old\(index).example", blocked: true, reason: "test",
																sourceApp: "com.example")
								}
								let trimmed = IOSDecisionCore.activityLogMergeAndTrim(
												existing: existing,
												newEntries: newEntries,
												maxTotal: 4,
												maxPerApp: 2
								)
								XCTAssertEqual(trimmed.count, 2)
								XCTAssertEqual(trimmed.map(\.displayDomain), ["new0.example", "new1.example"])
				}
}
