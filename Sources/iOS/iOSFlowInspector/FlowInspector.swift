//
//  FlowInspector.swift
//  iOSFlowInspector
//
//  Created by Tushar on 25.02.26.
//

import Foundation
import GetBoredCore
import NetworkExtension
import os.log

class FlowInspector: NEFilterDataProvider {

				private let logger = OSLog(
								subsystem: GetBoredIdentifiers.Logging.iOS, category: "FlowInspector")
				private let safariParentChildContextStore = SafariParentChildContextStore()
				private let safariParentChildObservationMaxAge: TimeInterval = 10

				/// Current filter mode, refreshed on every classification call
				private var currentMode: String = "blockSpecific"

				/// Throttle app-level block probes: one per app per 30 seconds
				private var lastAppProbeLogAt: [String: Date] = [:]
				private let appProbeCooldown: TimeInterval = 30

				// MARK: - Always-Allowed System Domains

				/// Apple infrastructure domains that must always be allowed.
				/// Blocking these breaks iCloud, App Store, certificate validation, etc.
				/// Reference: https://support.apple.com/en-us/101555
				private let systemAllowedSuffixes: [String] = SystemAllowList.load(
								from: Bundle(for: FlowInspector.self))

				/// Check if a host is an Apple system domain that should never be blocked
				private func isSystemAllowed(_ host: String) -> Bool {
								return IOSDecisionCore.isSystemAllowed(host, systemAllowedSuffixes: systemAllowedSuffixes)
				}

				// MARK: - Lifecycle

				/// Called by iOS when the content filter is activated.
				override func startFilter(completionHandler: @escaping (Error?) -> Void) {
								os_log("Filter starting – TLS SNI + HTTP Host inspection mode", log: logger, type: .info)
								currentMode = IOSRuleStore.shared.getMode()
								os_log("Filter initial mode: %{public}@", log: logger, type: .info, currentMode)
								completionHandler(nil)
				}

				/// Called by iOS when the content filter is deactivated.
				override func stopFilter(
								with reason: NEProviderStopReason, completionHandler: @escaping () -> Void
				) {
								os_log("Filter stopped: %{public}@", log: logger, type: .info, String(describing: reason))
								completionHandler()
				}

				// MARK: - Telemetry Helpers

				/// Logs a direct-drop outcome when no Control Provider escalation occurs.
				///
				/// Call flow:
				///
				///   handleOutboundData detects blocked SNI or HTTP host
				///           │
				///           └── logBlockedAppTelemetry(sourceApp:domain:reason:resolutionSource:)
				///                   ├── sourceApp nil/empty → return  ← no app identity to record
				///                   └── IOSActivityLogger.shared.log(...)  ← currently a release-1.0 no-op
				private func logBlockedAppTelemetry(
								sourceApp: String?, domain: String, reason: String, resolutionSource: String
				) {
								guard let sourceApp, !sourceApp.isEmpty else { return }
								os_log(
												"logBlockedAppTelemetry: sourceApp=%{public}@ domain=%{public}@",
												log: logger, type: .info, sourceApp, domain)
								IOSActivityLogger.shared.log(
												domain: domain,
												blocked: true,
												reason: reason,
												sourceApp: sourceApp,
												rawEndpoint: nil,
												resolutionSource: resolutionSource,
												isResolvableHostname: !domain.lowercased().hasPrefix("app:")
								)
				}

				// MARK: - Host Classification

				/// Classifies a hostname using the current App Group snapshot.
				///
				/// The same site rules list means different things depending on mode:
				/// - blockSpecific: the list is a BLOCKLIST (block what's listed)
				/// - whiteList: the list is an ALLOWLIST (allow what's listed, block everything else)
				///
				/// Release 1.0 only ships block mode. `IOSRuleStore` converts a stored
				/// `.whiteList` value to `.blockSpecific` before it reaches this method.
				/// The allow-list branch remains for the separate Safari spike targets; it
				/// is not a shipped release path.
				///
				/// Call flow:
				///
				///   classifyHost(host)
				///           │
				///           ├── loadFilterRules()              ← reads the latest shared snapshot
				///           ├── currentMode = rules.filterMode ← keeps telemetry in sync
				///           │
				///           ├── mode == .whiteList     → allowedSafariParent(forChildHost: host) (Safari spike only)
				///           └── mode == .blockSpecific → allowedParent = nil
				///                   │
				///                   ▼
				///           IOSDecisionCore.classifyHost(host, rules, systemAllowedSuffixes, allowedParent)
				///                   → (decision.blocked, decision.reason)
				private func classifyHost(_ host: String) -> (blocked: Bool, reason: String) {
								// Always re-read the mode — it could change at any time when the app
								// applies a fresh server policy snapshot (GET /api/policy → applyFilterListSnapshot).
								let loadedFilterRules = IOSRuleStore.shared.loadFilterRules()
								currentMode = loadedFilterRules.filterMode.rawValue

								let isAllowListMode = loadedFilterRules.filterMode == .whiteList
								let allowedParent: String?
								if isAllowListMode {
												allowedParent = allowedSafariParent(
																forChildHost: host,
																using: loadedFilterRules
												)
								} else {
												allowedParent = nil
								}

								let decision = IOSDecisionCore.classifyHost(
												host,
												using: loadedFilterRules,
												systemAllowedSuffixes: systemAllowedSuffixes,
												allowedSafariParent: allowedParent
								)
								return (decision.blocked, decision.reason)
				}

				/// Safari-spike helper that finds an allowed parent for a child hostname.
				///
				/// This only runs in allow-list mode, which Release 1.0 does not expose.
				///
				/// Call flow:
				///
				///   classifyHost(host)  [whiteList mode only]
				///           │
				///           └── allowedSafariParent(forChildHost: host, using: rules)
				///                   │
				///                   ├── safariParentChildContextStore.allowedSafariParentForChild(host, ...)
				///                   │       ├── returns nil  → no recent parent observation → return nil
				///                   │       └── returns decision
				///                   │               │
				///                   │               ├── appendEvent(decision.event)  ← side-effect: records this lookup
				///                   │               │
				///                   │               ├── decision.shouldAllow == false
				///                   │               │       → record the lookup → return nil
				///                   │               │
				///                   │               └── decision.shouldAllow == true
				///                   │                       → return decision.parentDomain
				///                   │
				///                   └── caller (classifyHost) passes parentDomain to IOSDecisionCore
				///                           so the child host inherits the parent's allow status
				///
				/// The event is recorded for both outcomes so the spike inspector shows each lookup.
				private func allowedSafariParent(
								forChildHost host: String, using loadedFilterRules: LoadedFilterRules
				) -> String? {
								guard
												let decision = safariParentChildContextStore.allowedSafariParentForChild(
																host,
																using: loadedFilterRules,
																maxAge: safariParentChildObservationMaxAge
												)
								else {
												return nil
								}

								safariParentChildContextStore.appendEvent(decision.event)

								guard decision.shouldAllow else {
												os_log(
																"allowedSafariParent: rejecting child=%{public}@ parent=%{public}@ because parent is not in allowlist",
																log: logger, type: .info, decision.requestHost, decision.parentDomain)
												return nil
								}

								os_log(
												"allowedSafariParent: allowing child=%{public}@ parent=%{public}@ age=%.1f",
												log: logger, type: .info, decision.requestHost, decision.parentDomain, decision.age)
								return decision.parentDomain
				}

				// MARK: - Telemetry Helpers

				/// Emit at most one "app probe" per app per cooldown window (30 s).
				/// In whiteList (block-everything) mode a blocked app fires dozens of requests;
				/// this throttles the Block Log to one entry per app per window.
				///
				/// Call flow:
				///
				///   handleNewFlow (per-app gate) → logBlockedAppProbeIfNeeded(sourceApp, rules)
				///           │
				///           ├── sourceApp nil/empty                       → return (no-op)
				///           ├── !shouldLogBlockedAppProbe(sourceApp)      → return (allowed app, or not whiteList)
				///           ├── last probe < 30 s ago (appProbeCooldown)  → return (throttled)
				///           │
				///           └── lastAppProbeLogAt[appKey] = now           ← side effect: arms the cooldown
				///                   │
				///                   ▼
				///               logBlockedAppTelemetry(domain: "app:<sourceApp>", …)
				private func logBlockedAppProbeIfNeeded(
								sourceApp: String?, using loadedFilterRules: LoadedFilterRules
				) {
								guard let sourceApp, !sourceApp.isEmpty else { return }
								guard IOSDecisionCore.shouldLogBlockedAppProbe(sourceApp, using: loadedFilterRules) else {
												return
								}
								let appKey = sourceApp.lowercased()
								let now = Date()
								let lastProbeAt = lastAppProbeLogAt[appKey]
								let probeIsWithinCooldown =
												lastProbeAt.map {
																now.timeIntervalSince($0) < appProbeCooldown
												} ?? false
								if probeIsWithinCooldown {
												return
								}
								lastAppProbeLogAt[appKey] = now
								logBlockedAppTelemetry(
												sourceApp: sourceApp,
												domain: "app:\(sourceApp)",
												reason: "Blocked by filter (app probe)",
												resolutionSource: "data-provider-app-probe"
								)
				}

				#if DEBUG
								/// Spike-only probe for deciding whether parent-child enforcement can live
								/// in the existing content filter instead of the Safari App Proxy.
								private func logParentChildOwnerProbe(flow: NEFilterFlow, host: String, url: URL) {
												let sourceApp = flow.sourceAppIdentifier ?? "nil"
												if let browserFlow = flow as? NEFilterBrowserFlow {
																let parentURL = browserFlow.parentURL?.absoluteString ?? "nil"
																let requestURL = browserFlow.request?.url?.absoluteString ?? "nil"
																os_log(
																				"PARENT_CHILD_OWNER_PROBE layer=DataProvider type=NEFilterBrowserFlow host=%{public}@ url=%{public}@ requestURL=%{public}@ parentURL=%{public}@ sourceApp=%{public}@",
																				log: logger,
																				type: .info,
																				host,
																				url.absoluteString,
																				requestURL,
																				parentURL,
																				sourceApp)
												} else {
																os_log(
																				"PARENT_CHILD_OWNER_PROBE layer=DataProvider type=%{public}@ host=%{public}@ url=%{public}@ parentURL=unavailable sourceApp=%{public}@",
																				log: logger,
																				type: .info,
																				String(describing: type(of: flow)),
																				host,
																				url.absoluteString,
																				sourceApp)
												}
								}
				#endif

				// MARK: - Flow Handling (Chunk 4)

				/// The busiest method in the whole filter — every network request on the phone goes through it.
				///
				/// SAFETY-CRITICAL ORDERING: the allow gate (own-app / Apple-system / parent-whitelisted) is
				/// evaluated FIRST and returns .allow() immediately. Only flows that nothing allowed reach the
				/// isAppBlocked .drop() check. Never reorder allow-before-drop — it is load-bearing:
				///   - Own-app traffic must never be dropped, or GetBored loses its own network + server
				///     API control channel and can no longer be managed/recovered remotely.
				///   - Apple system domains must never be dropped (breaks iCloud, App Store, cert validation).
				///   - A parent-whitelisted app is explicit parent intent and outranks any overlap with the
				///     admin blocked-apps list.
				/// If a bundle ID is in BOTH the allowed and blocked sets, allow wins by construction.
				///
				/// Call flow:
				///
				///   iOS detects new network connection → handleNewFlow(flow)
				///           │
				///           ├── sourceApp present (per-app gate, in this exact order):
				///           │       │
				///           │       ├── shouldAllowApp (own-app / Apple-system / whitelisted) → .allow()   ← MUST be first
				///           │       │
				///           │       ├── isAppBlocked (admin blocked-apps list)               → .drop()    ← only if not allowed above
				///           │       │
				///           │       └── shouldLogBlockedAppProbe (not-allowed + whiteList)   → logBlockedAppProbeIfNeeded (≤1 / 30 s)
				///           │
				///           ├── QUIC (UDP :443, SOCK_DGRAM — HTTP/3):
				///           │       ├── isSystemAllowed(host) → .allow()
				///           │       ├── classifyHost blocked  → .needRules()  (escalate to Control Provider)
				///           │       └── otherwise             → .allow()
				///           │
				///           ├── flow.url present (browser, e.g. Safari):
				///           │       ├── isSystemAllowed(host) → .allow()
				///           │       ├── classifyHost blocked
				///           │       │       ├── matchesException(url) → .allow()
				///           │       │       └── otherwise             → .needRules()
				///           │       └── otherwise             → .allow()
				///           │
				///           └── no URL (non-browser app: TikTok / Instagram / YouTube / Snapchat):
				///                   └── filterDataVerdict(peekOutboundBytes: 512)
				///                           → iOS calls handleOutboundData() next to sniff SNI / HTTP Host
				///
				/// Browsers and QUIC are handled completely here. Non-browser apps give us no URL
				/// (flow.url == nil); without handleOutboundData() peeking the first 512 bytes they would
				/// slip through unfiltered — that is most of the traffic on a teenager's phone.
				override func handleNewFlow(_ flow: NEFilterFlow) -> NEFilterNewFlowVerdict {
								let sourceApp = flow.sourceAppIdentifier
								let loadedFilterRules = IOSRuleStore.shared.loadFilterRules()

								// ── Step 1 & 2: Per-app checks ──────────────────────────────────
								if let sourceApp {
												os_log(
																"handleNewFlow: checking sourceApp=%{public}@", log: logger, type: .info, sourceApp)

												// `IOSDecisionCore` keeps own-app, Apple-system-app, and configured-app access together.
												if IOSDecisionCore.shouldAllowApp(sourceApp, using: loadedFilterRules) {
																if IOSDecisionCore.matchesAllowedApp(sourceApp, using: loadedFilterRules) {
																				os_log(
																								"handleNewFlow: allowing whitelisted app: %{public}@",
																								log: logger, type: .info, sourceApp)
																}
																return .allow()
												}

												// 3. Explicit app block — allow wins above, so own-app/system/allowed are already safe.
												if IOSDecisionCore.isAppBlocked(sourceApp, using: loadedFilterRules) {
																os_log(
																				"handleNewFlow: dropping blocked app: %{public}@", log: logger, type: .info,
																				sourceApp)
																return .drop()
												}

												// 4. App not allowed + whiteList → emit one app probe per cooldown window
												if IOSDecisionCore.shouldLogBlockedAppProbe(sourceApp, using: loadedFilterRules) {
																logBlockedAppProbeIfNeeded(sourceApp: sourceApp, using: loadedFilterRules)
												}
								}

								// ── Step 5: QUIC (HTTP/3) ───────────────────────────────────────
								// QUIC uses UDP port 443. Our TLS SNI parser only handles TCP,
								// but iOS can still provide the hostname on the socket flow. Prefer
								// remoteHostname because the endpoint hostname can be only an IP.
								if let socketFlow = flow as? NEFilterSocketFlow,
												let endpoint = socketFlow.remoteEndpoint as? NWHostEndpoint,
												endpoint.port == "443",
												socketFlow.socketType == Int32(SOCK_DGRAM)
								{
												let host = socketFlow.remoteHostname ?? endpoint.hostname
												if isSystemAllowed(host) {
																return .allow()
												}
												let result = classifyHost(host)
												if result.blocked {
																os_log(
																				"handleNewFlow: QUIC BLOCKED %{public}@ endpoint=%{public}@ → routing to CP",
																				log: logger, type: .info, host, endpoint.hostname)
																return .needRules()
												}
												return .allow()
								}

								// ── Step 6: Browser flows (have a URL) ──────────────────────────
								if let url = flow.url, let host = url.host?.lowercased() {
												#if DEBUG
																logParentChildOwnerProbe(flow: flow, host: host, url: url)
												#endif
												if isSystemAllowed(host) {
																return .allow()
												}
												let result = classifyHost(host)
												if result.blocked {
																// Check URL path exceptions (e.g. "instagram.com/school-account")
																if IOSDecisionCore.matchesException(url.absoluteString, using: loadedFilterRules) {
																				os_log(
																								"handleNewFlow: exception match for %{public}@",
																								log: logger, type: .info, url.absoluteString)
																				return .allow()
																}
																os_log(
																				"handleNewFlow: BLOCKED %{public}@ (%{public}@) → routing to CP",
																				log: logger, type: .info, host, result.reason)
																return .needRules()
												}
												return .allow()
								}

								// ── Step 6: No URL (non-browser app) ────────────────────────────
								// Ask iOS for the first 512 outbound bytes so we can parse
								// TLS ClientHello (SNI) or HTTP Host header in handleOutboundData()
								return NEFilterNewFlowVerdict.filterDataVerdict(
												withFilterInbound: false,
												peekInboundBytes: 0,
												filterOutbound: true,
												peekOutboundBytes: 512
								)
				}

				// MARK: - Outbound Data Inspection (Chunk 5)

				/// Callback for the "no URL" branch of handleNewFlow: no hostname was available there, so it
				/// requested the first 512 outbound bytes and iOS delivers them here. We sniff the hostname out
				/// of the raw bytes so non-browser apps (TikTok, Instagram, YouTube, Snapchat) can still be filtered.
				///
				/// KEY DIFFERENCE from handleNewFlow: this path uses .drop(), not .needRules(). By the time we
				/// inspect raw bytes, .needRules() no longer reliably triggers the Control Provider, so we drop
				/// directly and surface the event through logBlockedAppTelemetry().
				///
				/// Call flow:
				///
				///   iOS delivers 512 raw bytes → handleOutboundData()
				///           │
				///           ├── Try 1: extractSNI (TLS ClientHello — HTTPS, most apps)
				///           │       ├── isSystemAllowed(sni) → .allow()
				///           │       ├── classifyHost blocked → logBlockedAppTelemetry + .drop()
				///           │       └── otherwise            → .allow()
				///           │
				///           ├── Try 2: extractHTTPHost (plain HTTP "Host:" header — rare)
				///           │       ├── isSystemAllowed(host) → .allow()
				///           │       ├── classifyHost blocked
				///           │       │       ├── extractHTTPFullURL + matchesException → .allow()
				///           │       │       └── otherwise                            → logBlockedAppTelemetry + .drop()
				///           │       └── otherwise             → .allow()
				///           │
				///           └── neither TLS nor HTTP (DNS, mDNS, system traffic) → .allow()
				override func handleOutboundData(
								from flow: NEFilterFlow,
								readBytesStartOffset offset: Int,
								readBytes: Data
				) -> NEFilterDataVerdict {
								// ── Try 1: TLS ClientHello → extract SNI hostname ───────────────
								if let sni = IOSDecisionCore.extractSNI(from: readBytes) {
												if isSystemAllowed(sni) { return .allow() }
												let result = classifyHost(sni)
												if result.blocked {
																os_log(
																				"handleOutboundData: BLOCKED SNI %{public}@ (%{public}@)",
																				log: logger, type: .info, sni, result.reason)
																logBlockedAppTelemetry(
																				sourceApp: flow.sourceAppIdentifier,
																				domain: sni,
																				reason: result.reason,
																				resolutionSource: "data-provider-sni"
																)
																return .drop()
												}
												return .allow()
								}

								// ── Try 2: HTTP request → extract Host header ───────────────────
								if let host = IOSDecisionCore.extractHTTPHost(from: readBytes) {
												if isSystemAllowed(host) { return .allow() }
												let result = classifyHost(host)
												if result.blocked {
																// Check URL path exceptions for HTTP
																if let fullURL = IOSDecisionCore.extractHTTPFullURL(from: readBytes) {
																				let exceptionRules = IOSRuleStore.shared.loadFilterRules()
																				let isException = IOSDecisionCore.matchesException(
																								fullURL, using: exceptionRules)
																				if isException {
																								return .allow()
																				}
																}
																os_log(
																				"handleOutboundData: BLOCKED HTTP %{public}@ (%{public}@)",
																				log: logger, type: .info, host, result.reason)
																logBlockedAppTelemetry(
																				sourceApp: flow.sourceAppIdentifier,
																				domain: host,
																				reason: result.reason,
																				resolutionSource: "data-provider-http"
																)
																return .drop()
												}
												return .allow()
								}

								// ── Neither TLS nor HTTP — allow (DNS, mDNS, system traffic) ────
								return .allow()
				}

}
