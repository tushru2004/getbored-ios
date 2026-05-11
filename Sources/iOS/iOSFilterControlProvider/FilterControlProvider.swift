//
//  FilterControlProvider.swift
//  GetBored
//
//  Handles escalated flows from the Data Provider, activity logging,
//  block page display, and CloudKit upload.
//
//  The CP exists because the DP (Data Provider) runs in a restricted sandbox
//  and CANNOT write to UserDefaults. When DP blocks a flow, it returns
//  .needRules() which routes the flow here. The CP can write, so it logs
//  the block via IOSActivityLogger and uploads to CloudKit.
//

import CloudKit
import GetBoredCore
import NetworkExtension
import os.log

class FilterControlProvider: NEFilterControlProvider {

    private let logger = OSLog(subsystem: GetBoredIdentifiers.Logging.iOS, category: "FilterControlProvider")
    private let systemAllowedSuffixes: [String] = SystemAllowList.load(from: Bundle(for: FilterControlProvider.self))

    // MARK: - CloudKit Config

    private let cloudContainerID = GetBoredIdentifiers.CloudKit.containerIdentifier

    /// Debug builds write to a separate CloudKit record so testing doesn't corrupt production data
    #if DEBUG
    private let cloudRecordID = CKRecord.ID(recordName: GetBoredIdentifiers.CloudKit.RecordName.sharedFilterConfigDebug)
    #else
    private let cloudRecordID = CKRecord.ID(recordName: GetBoredIdentifiers.CloudKit.RecordName.sharedFilterConfigProduction)
    #endif

    /// Debounce timer for CloudKit uploads — waits 2s after last log before uploading
    private var pendingUploadWorkItem: DispatchWorkItem?

    // MARK: - Start Filter (Block Page Setup)

    /// Called once when iOS activates the content filter.
    /// We build the block page HTML here and store it in remediationMap
    /// so iOS knows what to show in Safari when a site is blocked.
    ///
    /// Flow:
    ///   DP returns .remediate() for browser flows
    ///     → iOS looks up CP's remediationMap
    ///       → Safari renders the base64 HTML block page
    ///         → User sees "Content Blocked" card with shield icon
    override func startFilter(completionHandler: @escaping (Error?) -> Void) {
        os_log("Control provider started", log: logger, type: .info)

        let blockPageHTML = """
        <!DOCTYPE html>
        <html lang="en">
        <head>
        <meta charset="UTF-8">
        <meta name="viewport" content="width=device-width, initial-scale=1.0, user-scalable=no">
        <title>Content Blocked</title>
        <style>
        *{margin:0;padding:0;box-sizing:border-box}
        body{font-family:-apple-system,BlinkMacSystemFont,system-ui,sans-serif;background:#f5f5f7;display:flex;justify-content:center;align-items:center;min-height:100vh;padding:24px;-webkit-text-size-adjust:none}
        .container{background:#fff;border-radius:16px;box-shadow:0 2px 20px rgba(0,0,0,.06);padding:48px 32px 36px;max-width:400px;width:100%;text-align:center}
        .icon{width:64px;height:64px;margin:0 auto 24px;background:linear-gradient(135deg,#34c759,#30d158);border-radius:16px;display:flex;align-items:center;justify-content:center}
        .icon svg{width:32px;height:32px;fill:#fff}
        h1{color:#1d1d1f;font-size:22px;font-weight:600;margin-bottom:8px;letter-spacing:-.02em}
        .subtitle{color:#86868b;font-size:15px;margin-bottom:28px;line-height:1.5}
        .blocked-url{background:#f5f5f7;border-radius:10px;padding:12px 16px;margin-bottom:24px;color:#1d1d1f;font-family:"SF Mono",Monaco,"Courier New",monospace;font-size:13px;word-break:break-all}
        .info{background:#f5f5f7;padding:14px 16px;margin-bottom:12px;text-align:left;border-radius:10px}
        .info-title{color:#1d1d1f;font-weight:600;margin-bottom:4px;font-size:13px}
        .info-text{color:#86868b;font-size:13px;line-height:1.4}
        .button{display:inline-block;background:#007aff;color:#fff;border:none;padding:12px 28px;border-radius:980px;font-size:15px;font-weight:600;cursor:pointer;margin-top:20px;-webkit-tap-highlight-color:transparent;transition:opacity .15s;text-decoration:none}
        .button:active{opacity:.7}
        .footer{margin-top:28px;color:#c7c7cc;font-size:12px}
        </style>
        </head>
        <body>
        <div class="container">
        <div class="icon"><svg viewBox="0 0 24 24" xmlns="http://www.w3.org/2000/svg"><path d="M12 1L3 5v6c0 5.55 3.84 10.74 9 12 5.16-1.26 9-6.45 9-12V5l-9-4z"/></svg></div>
        <h1>Content Blocked</h1>
        <p class="subtitle">This website is not on your approved list.</p>
        <div class="blocked-url" id="blockedUrl">this website</div>
        <div class="info"><div class="info-title">Why am I seeing this?</div><div class="info-text">Your device uses a content filter to help you stay focused and safe online. Only pre-approved websites are accessible.</div></div>
        <div class="info"><div class="info-title">Need access?</div><div class="info-text">Ask your parent or administrator to add this site via the GetBored macOS app.</div></div>
        <button class="button" onclick="window.history.back()">Go Back</button>
        <div class="footer">Protected by GetBored</div>
        </div>
        <script>
        try {
            var r = document.referrer;
            if (r) {
                var a = document.createElement('a');
                a.href = r;
                if (a.hostname) document.getElementById('blockedUrl').textContent = a.hostname;
            }
        } catch(e) {}
        </script>
        </body>
        </html>
        """

        let blockPageDataURL = "data:text/html;base64,\(Data(blockPageHTML.utf8).base64EncodedString())"

        remediationMap = [
            NEFilterProviderRemediationMapRemediationURLs: [
                "BlockedURL": blockPageDataURL as NSString
            ],
            NEFilterProviderRemediationMapRemediationButtonTexts: [
                "RemediationButton": "Go Back" as NSString
            ]
        ]

        os_log("Control provider ready with block page remediation", log: logger, type: .info)
        completionHandler(nil)
    }

    // MARK: - Stop Filter

    override func stopFilter(with reason: NEProviderStopReason, completionHandler: @escaping () -> Void) {
        os_log("Control provider stopped: %{public}@", log: logger, type: .info, String(describing: reason))
        completionHandler()
    }

    // MARK: - Handle Remediation (Block Page Button)

    /// Called when the user taps "Go Back" on the block page.
    /// We just drop the flow — there's nothing else to do.
    override func handleRemediation(for flow: NEFilterFlow, completionHandler: @escaping (NEFilterControlVerdict) -> Void) {
        completionHandler(.drop(withUpdateRules: false))
    }

    // MARK: - Handle Report (Post-Verdict Logging)

    /// Called by iOS AFTER the DP makes a verdict (.drop or .remediate).
    /// This is how we log blocks that the DP handled directly.
    ///
    /// .drop vs .remediate:
    ///   .remediate() → blocks the flow AND shows the "Content Blocked" page in Safari.
    ///                   Only works for browser flows where Safari can render HTML.
    ///   .drop()      → silently kills the connection. No block page.
    ///                   Used for non-browser apps (TikTok, Instagram, etc.)
    ///                   since there's no browser to show a page in.
    ///   Both kill the connection — .remediate() just adds a user-friendly page.
    ///
    /// Decision tree:
    ///   report.action == .drop or .remediate?
    ///     NO  → ignore (we only care about blocks)
    ///     YES → resolve hostname from flow metadata
    ///           → log via IOSActivityLogger
    ///           → schedule CloudKit upload (debounced 2s)
    ///
    /// Hostname resolution cascade (in resolveBlockedHost):
    ///   1. flow.url.host         → e.g. "instagram.com" (browser flows)
    ///   2. socket endpoint       → e.g. "api.tiktok.com" (non-browser)
    ///   3. reverse DNS of IP     → e.g. "142.250.80.14" → "google.com"
    ///   4. fallback to sourceApp → e.g. "app:com.unknown.app"
    override func handle(_ report: NEFilterReport) {
        let action = report.action
        guard action == .drop || action == .remediate else { return }

        let flow = report.flow
        let sourceApp = flow?.sourceAppIdentifier
        let resolution = resolveBlockedHost(from: flow, sourceApp: sourceApp)

        // Skip Apple infrastructure domains — they should be allowed by the DP
        // but may arrive here via system reports for transient/failed connections.
        if SystemAllowList.isSystemAllowed(resolution.displayDomain, suffixes: systemAllowedSuffixes) {
            os_log("handle(report): skipping Apple domain %{public}@", log: logger, type: .debug, resolution.displayDomain)
            return
        }

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
        scheduleActivityUpload()
    }

    // MARK: - Handle New Flow (CP Version — Escalated from DP)

    /// Called when DP returns .needRules() — iOS routes the flow here.
    ///
    /// This is DIFFERENT from DP's handleNewFlow:
    ///   - DP's handleNewFlow: inspects every flow, decides block/allow
    ///   - CP's handleNewFlow: only receives flows DP already decided to block
    ///                         but couldn't log (DP can't write to UserDefaults)
    ///
    /// Why does DP use .needRules() instead of .drop()?
    ///   .needRules() routes the flow to CP where we CAN log.
    ///   .drop() would block silently with no logging.
    ///   For browser flows, .needRules() also enables the block page.
    ///
    /// Decision tree:
    ///   DP returns .needRules()
    ///     → iOS delivers flow to CP's handleNewFlow()
    ///       → Is the app now in the allowed list? (race condition safety)
    ///         YES → allow the flow (parent added app between DP and CP)
    ///         NO  → extract hostname from flow
    ///              → log via IOSActivityLogger
    ///              → schedule CloudKit upload
    ///              → drop the flow
    override func handleNewFlow(_ flow: NEFilterFlow, completionHandler: @escaping (NEFilterControlVerdict) -> Void) {

        let sourceApp = flow.sourceAppIdentifier

        // Try to get hostname: first from URL (browser), then from socket endpoint (non-browser)
        let host = flow.url?.host?.lowercased()
            ?? (flow as? NEFilterSocketFlow)
                .flatMap { ($0.remoteEndpoint as? NWHostEndpoint)?.hostname.lowercased() }
            ?? "unknown"

        // Skip Apple infrastructure domains — shouldn't reach CP but handle defensively
        if SystemAllowList.isSystemAllowed(host, suffixes: systemAllowedSuffixes) {
            os_log("CP handleNewFlow: allowing Apple domain %{public}@", log: logger, type: .info, host)
            completionHandler(.allow(withUpdateRules: false))
            return
        }

        // Safety check: the parent might have added this app to the allowed list
        // between when DP made its decision and when CP received the flow.
        // This is a rare race condition but worth handling.
        if let sourceApp, IOSRuleStore.shared.isAppAllowed(sourceApp) {
            os_log("CP handleNewFlow: app is now allowed, passing through: %{public}@",
                   log: logger, type: .info, sourceApp)
            completionHandler(.allow(withUpdateRules: false))
            return
        }

        os_log("CP handleNewFlow: blocking host=%{public}@ sourceApp=%{public}@",
               log: logger, type: .info, host, sourceApp ?? "nil")

        // Log the block — this is the whole reason CP exists.
        // DP can't write to UserDefaults, but CP can.
        IOSActivityLogger.shared.log(
            domain: host,
            blocked: true,
            reason: "Blocked by filter",
            sourceApp: sourceApp
        )
        scheduleActivityUpload()

        // Drop the flow — the connection is blocked
        completionHandler(.drop(withUpdateRules: false))
    }

    // MARK: - Hostname Resolution

    /// Bundles the result of resolving a blocked flow's hostname.
    /// Used by handle(report:) to figure out what domain was actually blocked.
    private struct HostResolution {
        let displayDomain: String       // What we show in the block log (e.g. "instagram.com")
        let rawEndpoint: String?        // The raw IP or hostname from the socket (e.g. "157.240.1.35")
        let resolutionSource: String    // How we found it: "url-host", "socket-endpoint", "source-app-fallback", "unresolved"
        let isResolvableHostname: Bool  // true = real domain name, false = IP or app: fallback
    }

    /// Tries to figure out what domain was blocked, using a cascade of strategies.
    ///
    /// Resolution cascade (stops at first success):
    ///   1. flow.url.host         → "instagram.com" (browser flows)
    ///   2. socket endpoint       → "api.tiktok.com" (non-browser TCP)
    ///   3. [disabled] reverse DNS of IP → too slow/unreliable for filter extension
    ///   4. fallback to sourceApp → "app:com.unknown.app" (last resort)
    private func resolveBlockedHost(from flow: NEFilterFlow?, sourceApp: String?) -> HostResolution {
        let rawURLHost = flow?.url?.host
        let rawEndpoint = (flow as? NEFilterSocketFlow)
            .flatMap { ($0.remoteEndpoint as? NWHostEndpoint)?.hostname }
        let normalizedURLHost = normalizeHost(rawURLHost)
        let normalizedEndpoint = normalizeHost(rawEndpoint)

        // 1. Try URL host (browser flows like Safari give us this directly)
        if let urlHost = normalizedURLHost, isResolvableHost(urlHost) {
            return HostResolution(
                displayDomain: urlHost,
                rawEndpoint: normalizedEndpoint,
                resolutionSource: "url-host",
                isResolvableHostname: true
            )
        }

        // 2. Try socket endpoint hostname (non-browser apps)
        if let endpointHost = normalizedEndpoint, isResolvableHost(endpointHost) {
            return HostResolution(
                displayDomain: endpointHost,
                rawEndpoint: endpointHost,
                resolutionSource: "socket-endpoint",
                isResolvableHostname: true
            )
        }

        // 3. Reverse DNS — disabled for now.
        //    In practice, reverse DNS is slow and returns unhelpful results
        //    like "lax17s55-in-f14.1e100.net" instead of "google.com".
        //    Uncomment if block log entries are too vague.
        //
        // if let endpointHost = normalizedEndpoint, isIPAddress(endpointHost),
        //    let reverseResolved = reverseDNS(for: endpointHost) {
        //     return HostResolution(
        //         displayDomain: reverseResolved,
        //         rawEndpoint: endpointHost,
        //         resolutionSource: "reverse-dns",
        //         isResolvableHostname: true
        //     )
        // }
        //
        // if let urlHost = normalizedURLHost, isIPAddress(urlHost),
        //    let reverseResolved = reverseDNS(for: urlHost) {
        //     return HostResolution(
        //         displayDomain: reverseResolved,
        //         rawEndpoint: urlHost,
        //         resolutionSource: "reverse-dns-url",
        //         isResolvableHostname: true
        //     )
        // }

        // 4. Fallback — use source app bundle ID or whatever we have
        let fallback = sourceAppLabel(sourceApp)
            ?? normalizedURLHost
            ?? normalizedEndpoint
            ?? "unknown-blocked-flow"
        let endpoint = normalizedEndpoint ?? normalizedURLHost
        return HostResolution(
            displayDomain: fallback,
            rawEndpoint: endpoint,
            resolutionSource: sourceApp != nil ? "source-app-fallback" : "unresolved",
            isResolvableHostname: false
        )
    }

    // MARK: - Hostname Helpers

    /// Trim trailing dots, lowercase, reject empty or "unknown"
    private func normalizeHost(_ value: String?) -> String? {
        guard let value else { return nil }
        let host = value.trimmingCharacters(in: CharacterSet(charactersIn: ".")).lowercased()
        guard !host.isEmpty, host != "unknown" else { return nil }
        return host
    }

    /// A resolvable host is a real domain name — not an IP address, not an "app:" fallback
    private func isResolvableHost(_ host: String) -> Bool {
        !isIPAddress(host) && !host.hasPrefix("app:")
    }

    /// Format a bundle ID as a fallback label: "com.apple.mobilesafari" → "app:com.apple.mobilesafari"
    private func sourceAppLabel(_ sourceApp: String?) -> String? {
        guard let sourceApp, !sourceApp.isEmpty else { return nil }
        return "app:\(sourceApp)"
    }

    /// Detect IPv4 or IPv6 addresses using C inet_pton
    private func isIPAddress(_ host: String) -> Bool {
        let normalized = host.trimmingCharacters(in: CharacterSet(charactersIn: "[] .")).lowercased()
        var ipv4 = in_addr()
        if normalized.withCString({ inet_pton(AF_INET, $0, &ipv4) }) == 1 { return true }
        var ipv6 = in6_addr()
        if normalized.withCString({ inet_pton(AF_INET6, $0, &ipv6) }) == 1 { return true }
        return false
    }

    // Reverse DNS — commented out, available if needed later.
    // Uses getaddrinfo/getnameinfo to resolve IP → hostname.
    //
    // private func reverseDNS(for ip: String) -> String? {
    //     var hints = addrinfo(
    //         ai_flags: AI_NUMERICHOST, ai_family: AF_UNSPEC,
    //         ai_socktype: 0, ai_protocol: 0, ai_addrlen: 0,
    //         ai_canonname: nil, ai_addr: nil, ai_next: nil
    //     )
    //     var result: UnsafeMutablePointer<addrinfo>?
    //     guard getaddrinfo(ip, nil, &hints, &result) == 0, let addr = result else { return nil }
    //     defer { freeaddrinfo(addr) }
    //     var hostBuffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
    //     guard getnameinfo(
    //         addr.pointee.ai_addr, socklen_t(addr.pointee.ai_addrlen),
    //         &hostBuffer, socklen_t(hostBuffer.count),
    //         nil, 0, NI_NAMEREQD
    //     ) == 0 else { return nil }
    //     let resolved = String(cString: hostBuffer)
    //         .trimmingCharacters(in: CharacterSet(charactersIn: ".")).lowercased()
    //     guard !resolved.isEmpty, !isIPAddress(resolved) else { return nil }
    //     return resolved
    // }

    // MARK: - CloudKit Upload

    /// Debounced upload — waits 2 seconds after the last log before uploading.
    ///
    /// Why debounce?
    ///   When a user opens an app like TikTok, it makes 10-20 network requests
    ///   in the first second. Without debouncing, we'd upload to CloudKit 10-20
    ///   times. Instead, we cancel the previous timer and start a new 2s timer
    ///   each time. The upload only fires once, after the burst settles.
    ///
    /// Timeline example:
    ///   0.0s  block tiktok.com     → schedule upload at 2.0s
    ///   0.1s  block api.tiktok.com → cancel, reschedule at 2.1s
    ///   0.3s  block cdn.tiktok.com → cancel, reschedule at 2.3s
    ///   (no more blocks)
    ///   2.3s  upload fires — all 3 entries go up in one batch
    private func scheduleActivityUpload() {
        pendingUploadWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.uploadActivityLogToCloudKit()
        }
        pendingUploadWorkItem = work
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 2, execute: work)
    }

    /// Reads all activity log entries from UserDefaults and uploads to CloudKit.
    ///
    /// Flow:
    ///   1. Flush any pending in-memory entries to UserDefaults
    ///   2. Read all entries from UserDefaults
    ///   3. JSON-encode them
    ///   4. Fetch the existing CloudKit record
    ///   5. Update the "activityLogJSON" field
    ///   6. Save back to CloudKit
    ///
    /// The macOS companion app reads this field to show the Block Log.
    private func uploadActivityLogToCloudKit() {
        // Flush pending in-memory entries to disk before reading
        IOSActivityLogger.shared.flushSync()

        let entries = IOSActivityLogger.shared.loadEntries()
        os_log("uploadActivityLog: loaded %{public}d entries from UserDefaults",
               log: logger, type: .info, entries.count)

        guard !entries.isEmpty,
              let data = try? JSONEncoder().encode(entries),
              let json = String(data: data, encoding: .utf8) else {
            return
        }

        let db = CKContainer(identifier: cloudContainerID).privateCloudDatabase

        // Fetch existing record, update the activity log field, save it back
        db.fetch(withRecordID: cloudRecordID) { [weak self] record, error in
            guard let self else { return }

            if let error {
                os_log("uploadActivityLog: fetch failed: %{public}@",
                       log: self.logger, type: .error, error.localizedDescription)
                return
            }
            guard let record else {
                os_log("uploadActivityLog: missing CloudKit record",
                       log: self.logger, type: .error)
                return
            }

            record[GetBoredIdentifiers.CloudKit.Field.activityLogJSON] = json as NSString

            db.save(record) { _, saveError in
                if let saveError {
                    os_log("uploadActivityLog: save failed: %{public}@",
                           log: self.logger, type: .error, saveError.localizedDescription)
                } else {
                    os_log("uploadActivityLog: uploaded %{public}d entries",
                           log: self.logger, type: .info, entries.count)
                }
            }
        }
    }
}
