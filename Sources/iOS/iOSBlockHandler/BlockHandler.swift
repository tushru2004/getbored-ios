//
//  BlockHandler.swift
//  GetBored
//
//  Handles escalated flows from the Data Provider, activity logging,
//  and CloudKit upload.
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

class BlockHandler: NEFilterControlProvider {

    private let logger = OSLog(subsystem: GetBoredIdentifiers.Logging.iOS, category: "BlockHandler")

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

    // MARK: - Start / Stop Filter

    override func startFilter(completionHandler: @escaping (Error?) -> Void) {
        os_log("Control provider started", log: logger, type: .info)
        completionHandler(nil)
    }

    override func stopFilter(with reason: NEProviderStopReason, completionHandler: @escaping () -> Void) {
        os_log("Control provider stopped: %{public}@", log: logger, type: .info, String(describing: reason))
        completionHandler()
    }

    // MARK: - Handle Report (Post-Verdict Logging)

    /// Called by iOS AFTER the DP makes a verdict.
    /// This is how we log blocks that the DP handled directly.
    ///
    /// Decision tree:
    ///   report.action == .drop?
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

    /// Tries to figure out what domain was blocked, using a cascade of strategies.
    ///
    /// Resolution cascade (stops at first success):
    ///   1. flow.url.host         → "instagram.com" (browser flows)
    ///   2. socket endpoint       → "api.tiktok.com" (non-browser TCP)
    ///   3. [disabled] reverse DNS of IP → too slow/unreliable for filter extension
    ///   4. fallback to sourceApp → "app:com.unknown.app" (last resort)
    private func resolveBlockedHost(from flow: NEFilterFlow?, sourceApp: String?) -> KMPDecisionCoreAdapter.BlockedHostResolution {
        let rawURLHost = flow?.url?.host
        let rawEndpoint = (flow as? NEFilterSocketFlow)
            .flatMap { ($0.remoteEndpoint as? NWHostEndpoint)?.hostname }
        return KMPDecisionCoreAdapter.resolveBlockedHost(
            rawURLHost: rawURLHost,
            rawEndpoint: rawEndpoint,
            sourceApp: sourceApp
        )
    }

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
