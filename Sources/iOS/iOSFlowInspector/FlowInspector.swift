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

    private let logger = OSLog(subsystem: GetBoredIdentifiers.Logging.iOS, category: "FlowInspector")
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
    private let systemAllowedSuffixes: [String] = SystemAllowList.load(from: Bundle(for: FlowInspector.self))

    /// Check if a host is an Apple system domain that should never be blocked
    private func isSystemAllowed(_ host: String) -> Bool {
        return KMPDecisionCoreAdapter.isSystemAllowed(host, systemAllowedSuffixes: systemAllowedSuffixes)
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
    override func stopFilter(with reason: NEProviderStopReason, completionHandler: @escaping () -> Void) {
        os_log("Filter stopped: %{public}@", log: logger, type: .info, String(describing: reason))
        completionHandler()
    }

    // MARK: - Telemetry Helpers

    /// Log a blocked app event. Fallback telemetry when the normal
    /// CP logging path (via .needRules()) doesn't reliably surface the app.
    private func logBlockedAppTelemetry(sourceApp: String?, domain: String, reason: String, resolutionSource: String) {
        guard let sourceApp, !sourceApp.isEmpty else { return }
        os_log("logBlockedAppTelemetry: sourceApp=%{public}@ domain=%{public}@",
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

    /// The decision engine. Returns (shouldBlock, reason) for a given hostname.
    /// Called every time we extract a hostname from a network flow.
    ///
    /// The same site rules list means different things depending on mode:
    /// - blockSpecific: the list is a BLOCKLIST (block what's listed)
    /// - whiteList: the list is an ALLOWLIST (allow what's listed, block everything else)
    private func classifyHost(_ host: String) -> (blocked: Bool, reason: String) {
        // Always re-read the mode — it could change at any time via CloudKit sync
        let loadedFilterRules = IOSRuleStore.shared.loadFilterRules()
        currentMode = loadedFilterRules.filterMode.rawValue
        let allowedParent = loadedFilterRules.filterMode == .whiteList
            ? allowedSafariParent(forChildHost: host, using: loadedFilterRules)
            : nil
        let decision = KMPDecisionCoreAdapter.classifyHost(
            host,
            using: loadedFilterRules,
            systemAllowedSuffixes: systemAllowedSuffixes,
            allowedSafariParent: allowedParent
        )
        return (decision.blocked, decision.reason)
    }

    /// Returns the allowed parent domain for a child hostname in whiteList mode, or nil if the child should be blocked.
    ///
    /// Only called from classifyHost() when mode == .whiteList. The purpose is to allow
    /// subresource requests (e.g. cdn.instagram.com) that originate from a parent page
    /// (e.g. instagram.com) that is itself on the allowlist.
    ///
    /// Call flow:
    ///
    ///   classifyHost(host)  [whiteList mode only]
    ///           │
    ///           └── allowedSafariParent(forChildHost: host, using: rules)
    ///                   │
    ///                   ├── safariParentChildContextStore.allowedSafariParentForChild(host, ...)
    ///                   │       ├── returns nil  → no recent parent observation found → return nil (block child)
    ///                   │       └── returns decision
    ///                   │               │
    ///                   │               ├── appendEvent(decision.event)  ← side-effect: records this lookup
    ///                   │               │
    ///                   │               ├── decision.shouldAllow == false
    ///                   │               │       → log "parent not in allowlist" → return nil (block child)
    ///                   │               │
    ///                   │               └── decision.shouldAllow == true
    ///                   │                       → log "allowing child via parent" → return decision.parentDomain
    ///                   │
    ///                   └── caller (classifyHost) passes parentDomain to KMPDecisionCoreAdapter
    ///                           so the child host inherits the parent's allow status
    ///
    /// NOTE: appendEvent() is always called even when shouldAllow is false — it records
    /// that the child was seen, so future lookups for the same child can be de-duplicated.
    private func allowedSafariParent(forChildHost host: String, using loadedFilterRules: LoadedFilterRules) -> String? {
        guard let decision = safariParentChildContextStore.allowedSafariParentForChild(
            host,
            using: loadedFilterRules,
            maxAge: safariParentChildObservationMaxAge
        ) else {
            return nil
        }

        safariParentChildContextStore.appendEvent(decision.event)

        guard decision.shouldAllow else {
            os_log("allowedSafariParent: rejecting child=%{public}@ parent=%{public}@ because parent is not in allowlist",
                   log: logger, type: .info, decision.requestHost, decision.parentDomain)
            return nil
        }

        os_log("allowedSafariParent: allowing child=%{public}@ parent=%{public}@ age=%.1f",
               log: logger, type: .info, decision.requestHost, decision.parentDomain, decision.age)
        return decision.parentDomain
    }

    // MARK: - Telemetry Helpers

    /// Emit at most one "app probe" per app per cooldown window.
    /// In block-everything mode, a blocked app sends dozens of requests.
    /// This limits to one log entry per app every 30 seconds.
    private func logBlockedAppProbeIfNeeded(sourceApp: String?, using loadedFilterRules: LoadedFilterRules) {
        guard let sourceApp, !sourceApp.isEmpty else { return }
        guard KMPDecisionCoreAdapter.shouldLogBlockedAppProbe(sourceApp, using: loadedFilterRules) else {
            return
        }
        let appKey = sourceApp.lowercased()
        let now = Date()
        if let last = lastAppProbeLogAt[appKey], now.timeIntervalSince(last) < appProbeCooldown {
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
            os_log("PARENT_CHILD_OWNER_PROBE layer=DataProvider type=NEFilterBrowserFlow host=%{public}@ url=%{public}@ requestURL=%{public}@ parentURL=%{public}@ sourceApp=%{public}@",
                   log: logger,
                   type: .info,
                   host,
                   url.absoluteString,
                   requestURL,
                   parentURL,
                   sourceApp)
        } else {
            os_log("PARENT_CHILD_OWNER_PROBE layer=DataProvider type=%{public}@ host=%{public}@ url=%{public}@ parentURL=unavailable sourceApp=%{public}@",
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

    /// This is the busiest method in the whole filter. Every single network request
    /// on the phone goes through it. Here's the decision tree:
    ///
    /// iOS detects new network connection → handleNewFlow(flow)
    ///     │
    ///     ├─ 1. Is it an Apple system app (not Safari)?
    ///     │     YES → .allow()  (Apple apps use weird CDN domains, let them through)
    ///     │
    ///     ├─ 2. Is the app in the user's allowed-apps list?
    ///     │     YES → .allow()  (parent explicitly whitelisted this app)
    ///     │
    ///     ├─ 3. Is the app in the admin's blocked-apps list?
    ///     │     YES → .drop()   (always AFTER steps 1–2 so own-app/system never blocked)
    ///     │
    ///     ├─ 4. App not allowed + whiteList mode?
    ///     │     YES → log one "app probe" per 30 seconds (for the Block Log)
    ///     │
    ///     ├─ 5. Is this QUIC? (UDP port 443, used by HTTP/3)
    ///     │     YES → classifyHost(endpoint.hostname)
    ///     │           blocked? → .needRules() (escalate to Control Provider)
    ///     │
    ///     ├─ 6. Does the flow have a URL? (browser like Safari)
    ///     │     YES → classifyHost(host)
    ///     │           blocked? → check exceptions first, then .needRules()
    ///     │
    ///     └─ 7. No URL? (non-browser app like TikTok, Instagram app)
    ///           → "Give me the first 512 outbound bytes to inspect"
    ///           → iOS will call handleOutboundData() next
    ///
    /// This method handles browsers (step 6) and QUIC (step 5) completely.
    /// But non-browser apps like TikTok, Instagram, YouTube, Snapchat give us
    /// NO URL — flow.url is nil. Without chunk 5 (handleOutboundData), every
    /// non-browser app would slip through unfiltered. That's most of the traffic
    /// on a teenager's phone.
    override func handleNewFlow(_ flow: NEFilterFlow) -> NEFilterNewFlowVerdict {
        let sourceApp = flow.sourceAppIdentifier
        let loadedFilterRules = IOSRuleStore.shared.loadFilterRules()

        // ── Step 1 & 2: Per-app checks ──────────────────────────────────
        if let sourceApp {
            os_log("handleNewFlow: checking sourceApp=%{public}@", log: logger, type: .info, sourceApp)

            // 1 & 2. KMP policy keeps own-app, Apple-system-app, and user app allow logic together.
            if KMPDecisionCoreAdapter.shouldAllowApp(sourceApp, using: loadedFilterRules) {
                if KMPDecisionCoreAdapter.matchesAllowedApp(sourceApp, using: loadedFilterRules) {
                    os_log("handleNewFlow: allowing whitelisted app: %{public}@",
                           log: logger, type: .info, sourceApp)
                }
                return .allow()
            }

            // 3. Explicit app block — allow wins above, so own-app/system/allowed are already safe.
            if KMPDecisionCoreAdapter.isAppBlocked(sourceApp, using: loadedFilterRules) {
                os_log("handleNewFlow: dropping blocked app: %{public}@", log: logger, type: .info, sourceApp)
                return .drop()
            }

            // 4. App not allowed + whiteList → emit one app probe per cooldown window
            if KMPDecisionCoreAdapter.shouldLogBlockedAppProbe(sourceApp, using: loadedFilterRules) {
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
           socketFlow.socketType == Int32(SOCK_DGRAM) {
            let host = socketFlow.remoteHostname ?? endpoint.hostname
            if isSystemAllowed(host) {
                return .allow()
            }
            let result = classifyHost(host)
            if result.blocked {
                os_log("handleNewFlow: QUIC BLOCKED %{public}@ endpoint=%{public}@ → routing to CP",
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
                if KMPDecisionCoreAdapter.matchesException(url.absoluteString, using: loadedFilterRules) {
                    os_log("handleNewFlow: exception match for %{public}@",
                           log: logger, type: .info, url.absoluteString)
                    return .allow()
                }
                os_log("handleNewFlow: BLOCKED %{public}@ (%{public}@) → routing to CP",
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

    /// This is the callback for step 6 above. When handleNewFlow() couldn't find
    /// a hostname (non-browser apps like TikTok, Instagram, YouTube, Snapchat),
    /// it asked iOS for the first 512 outbound bytes. iOS delivers them here.
    ///
    /// We dig through the raw bytes to find the hostname:
    ///
    /// iOS delivers 512 raw bytes → handleOutboundData()
    ///     │
    ///     ├─ Try 1: Is this a TLS ClientHello? (HTTPS — most apps)
    ///     │   extractSNI() parses the binary TLS record
    ///     │   Found hostname → classifyHost() → blocked? → .drop()
    ///     │
    ///     ├─ Try 2: Is this an HTTP request? (plain HTTP — rare)
    ///     │   extractHTTPHost() reads the "Host:" header
    ///     │   Found hostname → classifyHost() → check exceptions → .drop()
    ///     │
    ///     └─ Neither? (DNS, mDNS, system traffic)
    ///           → .allow()
    ///
    /// KEY DIFFERENCE from handleNewFlow: we use .drop() here, not .needRules().
    /// By the time we're inspecting raw bytes, .needRules() doesn't reliably
    /// trigger the Control Provider. So we drop directly and log via telemetry.
    override func handleOutboundData(from flow: NEFilterFlow,
                                     readBytesStartOffset offset: Int,
                                     readBytes: Data) -> NEFilterDataVerdict {
        // ── Try 1: TLS ClientHello → extract SNI hostname ───────────────
        if let sni = KMPDecisionCoreAdapter.extractSNI(from: readBytes) {
            if isSystemAllowed(sni) { return .allow() }
            let result = classifyHost(sni)
            if result.blocked {
                os_log("handleOutboundData: BLOCKED SNI %{public}@ (%{public}@)",
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
        if let host = KMPDecisionCoreAdapter.extractHTTPHost(from: readBytes) {
            if isSystemAllowed(host) { return .allow() }
            let result = classifyHost(host)
            if result.blocked {
                // Check URL path exceptions for HTTP
                if let fullURL = KMPDecisionCoreAdapter.extractHTTPFullURL(from: readBytes) {
                    let exceptionRules = IOSRuleStore.shared.loadFilterRules()
                    let isException = KMPDecisionCoreAdapter.matchesException(fullURL, using: exceptionRules)
                    if isException {
                        return .allow()
                    }
                }
                os_log("handleOutboundData: BLOCKED HTTP %{public}@ (%{public}@)",
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
