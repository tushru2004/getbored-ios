//
//  BlockHandler.swift
//  GetBored
//
//  Handles flows escalated by the Data Provider.
//
//  For a blocked browser or QUIC flow, the Data Provider returns `.needRules()`.
//  iOS then calls this Control Provider to make the final allow/drop verdict.
//  It also supplies the local block-log call site.
//

import GetBoredCore
import NetworkExtension
import os.log

class BlockHandler: NEFilterControlProvider {

    private let logger = OSLog(subsystem: GetBoredIdentifiers.Logging.iOS, category: "BlockHandler")

    // MARK: - Start / Stop Filter

    override func startFilter(completionHandler: @escaping (Error?) -> Void) {
        os_log("Control provider started", log: logger, type: .info)
        completionHandler(nil)
    }

    override func stopFilter(
        with reason: NEProviderStopReason, completionHandler: @escaping () -> Void
    ) {
        os_log(
            "Control provider stopped: %{public}@", log: logger, type: .info,
            String(describing: reason))
        completionHandler()
    }

    // MARK: - Handle Report (Post-Verdict Logging)

    /// Receives a post-verdict report for a flow the Data Provider handled directly.
    ///
    /// Hostname resolution cascade (in resolveBlockedHost):
    ///   1. flow.url.host         → e.g. "instagram.com" (browser flows)
    ///   2. socket endpoint       → e.g. "api.tiktok.com" (non-browser)
    ///   3. fallback to sourceApp → e.g. "app:com.unknown.app"
    ///
    /// Call flow:
    ///
    ///   iOS delivers post-verdict report → handle(report)
    ///           │
    ///           ├── report.action != .drop → return  (we only log blocks)
    ///           │
    ///           └── report.action == .drop
    ///                   │
    ///                   ▼
    ///               resolveBlockedHost(from: flow, sourceApp:)  ← runs the cascade above
    ///                   │
    ///                   ▼
    ///               IOSActivityLogger.shared.log(blocked: true, …)  ← local-only block log
    override func handle(_ report: NEFilterReport) {
        let action = report.action
        guard action == .drop else { return }

        let flow = report.flow
        let sourceApp = flow?.sourceAppIdentifier
        let resolution = resolveBlockedHost(from: flow, sourceApp: sourceApp)

        os_log(
            "handle(report): domain=%{public}@ source=%{public}@ resolvable=%{public}@ endpoint=%{public}@ sourceApp=%{public}@ event=%{public}d action=%{public}d",
            log: logger,
            type: .info,
            resolution.displayDomain,
            resolution.resolutionSource,
            resolution.isResolvableHostname ? "true" : "false",
            resolution.rawEndpoint ?? "nil",
            sourceApp ?? "nil",
            report.event.rawValue,
            action.rawValue
        )

        IOSActivityLogger.shared.log(
            domain: resolution.displayDomain,
            blocked: true,
            reason: "Blocked by filter",
            sourceApp: sourceApp,
            rawEndpoint: resolution.rawEndpoint,
            resolutionSource: resolution.resolutionSource,
            isResolvableHostname: resolution.isResolvableHostname
        )
    }

    // MARK: - Handle New Flow (CP Version — Escalated from DP)

    /// Handles a flow escalated when the Data Provider returns `.needRules()`.
    ///
    /// `FlowInspector` evaluates every new flow. It uses this provider for
    /// blocked browser and QUIC flows so iOS can request the final verdict.
    ///
    /// Call flow:
    ///
    ///   DP returns .needRules() → iOS delivers flow to CP handleNewFlow(flow)
    ///           │
    ///           ├── extract host: flow.url.host ?? socket endpoint ?? "unknown"
    ///           │
    ///           ├── sourceApp is now in the allowed list? (DP→CP race safety)
    ///           │       └── YES → completionHandler(.allow)  ← parent added app between DP and CP
    ///           │
    ///           └── NO (still blocked)
    ///                   ├── IOSActivityLogger.shared.log(blocked: true, …)
    ///                   └── completionHandler(.drop)
    override func handleNewFlow(
        _ flow: NEFilterFlow, completionHandler: @escaping (NEFilterControlVerdict) -> Void
    ) {

        let sourceApp = flow.sourceAppIdentifier

        // Try to get hostname: first from URL (browser), then from socket endpoint (non-browser)
        let browserURLHost = flow.url?.host?.lowercased()
        let socketEndpointHost = (flow as? NEFilterSocketFlow)
            .flatMap { ($0.remoteEndpoint as? NWHostEndpoint)?.hostname.lowercased() }
        let resolvedHost = browserURLHost ?? socketEndpointHost ?? "unknown"

        // Safety check: the parent might have added this app to the allowed list
        // between when DP made its decision and when CP received the flow.
        // This is a rare race condition but worth handling.
        if let sourceApp, IOSRuleStore.shared.isAppAllowed(sourceApp) {
            os_log(
                "CP handleNewFlow: app is now allowed, passing through: %{public}@",
                log: logger, type: .info, sourceApp)
            completionHandler(.allow(withUpdateRules: false))
            return
        }

        os_log(
            "CP handleNewFlow: blocking host=%{public}@ sourceApp=%{public}@",
            log: logger, type: .info, resolvedHost, sourceApp ?? "nil")

        // Log the block — this is the whole reason CP exists.
        // DP can't write to UserDefaults, but CP can.
        IOSActivityLogger.shared.log(
            domain: resolvedHost,
            blocked: true,
            reason: "Blocked by filter",
            sourceApp: sourceApp
        )

        // Drop the flow — the connection is blocked
        completionHandler(.drop(withUpdateRules: false))
    }

    /// Resolves a reportable domain for a blocked flow without performing network I/O.
    ///
    /// Resolution cascade (stops at first success):
    ///   1. flow.url.host         → "instagram.com" (browser flows)
    ///   2. socket endpoint       → "api.tiktok.com" (non-browser TCP)
    ///   3. [disabled] reverse DNS of IP → too slow/unreliable for filter extension
    ///   4. fallback to sourceApp → "app:com.unknown.app" (last resort)
    ///
    /// Call flow:
    ///
    ///   handle(report) → resolveBlockedHost(flow, sourceApp)
    ///           │
    ///           ├── extract URL host and socket endpoint when present
    ///           └── IOSDecisionCore.resolveBlockedHost(...) → display domain + resolution metadata
    private func resolveBlockedHost(from flow: NEFilterFlow?, sourceApp: String?)
        -> IOSDecisionCore.BlockedHostResolution
    {
        let rawURLHost = flow?.url?.host
        let rawEndpoint = (flow as? NEFilterSocketFlow)
            .flatMap { ($0.remoteEndpoint as? NWHostEndpoint)?.hostname }
        return IOSDecisionCore.resolveBlockedHost(
            rawURLHost: rawURLHost,
            rawEndpoint: rawEndpoint,
            sourceApp: sourceApp
        )
    }
}
