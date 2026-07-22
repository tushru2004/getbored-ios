import Foundation
import MetricKit
import OSLog
import UIKit
import React
import GetBoredCore

// ─── Wire format (mirrors POST /api/client-events) ─────────────────────────

private struct ClientLogEvent: Encodable {
    let timestamp: String
    let level: String
    let category: String
    let message: String
}

private struct ClientContext: Encodable {
    let appVersion: String
    let build: String
    let iosVersion: String
    let deviceModel: String
}

private struct ClientEventsRequest: Encodable {
    let reason: String
    let context: ClientContext
    let events: [ClientLogEvent]
}

/// Client-side cap, matching the server's MAX_EVENTS_PER_BATCH: sending more
/// is wasted bytes — the server truncates anyway.
private let maxEventsPerBatch = 300

/// How far back a snapshot reaches. Ten minutes comfortably covers "the user
/// tapped something, it failed, they tapped Report" without shipping a day of
/// noise.
private let snapshotWindow: TimeInterval = 10 * 60

/// Remote diagnostics, exposed to JS as `NativeModules.Diagnostics`.
///
/// The Apple-native error-reporting pipeline: every native module already
/// writes structured entries via `Logger` (unified logging). This module
/// reads those same entries back out of `OSLogStore` — the exact stream
/// Console.app shows for this process — and POSTs a recent window of them
/// to the backend, where they land in the server log. "Console.app over
/// the network", no cable required.
///
/// Reporting is strictly best-effort: every failure path resolves (never
/// rejects) — a failure to report an error must never become a second
/// user-visible error.
@objc(Diagnostics)
final class DiagnosticsModule: NSObject {

    @objc static func requiresMainQueueSetup() -> Bool { false }

    // MARK: - reportRecentLogs

    /// Snapshot the app's own recent unified-log entries and ship them.
    ///
    /// Call flow:
    ///
    ///   JS calls reportRecentLogs(reason)
    ///           │
    ///           ▼ (background queue — OSLogStore enumeration can take ~100s of ms)
    ///   collectRecentEvents()
    ///           │
    ///           ├── OSLogStore unavailable/thorws → events = []   ← still sends context
    ///           └── entries filtered to com.getbored* subsystems, newest 300 kept
    ///           ▼
    ///   Self.sendBatch(reason, events)
    ///           ├── .success → resolve(["sent": true,  "events": N])
    ///           └── .failure → resolve(["sent": false, "events": N])   ← never rejects
    @objc func reportRecentLogs(_ reason: String,
                                resolver resolve: @escaping RCTPromiseResolveBlock,
                                rejecter reject: @escaping RCTPromiseRejectBlock) {
        DispatchQueue.global(qos: .utility).async {
            let events = Self.collectRecentEvents()
            Self.sendBatch(reason: reason, events: events) { sent in
                resolve(["sent": sent, "events": events.count])
            }
        }
    }

    // MARK: - OSLogStore snapshot

    /// The app's own entries from the last [snapshotWindow], oldest first,
    /// capped to the NEWEST [maxEventsPerBatch] (the tail is where the error
    /// that triggered the report lives).
    private static func collectRecentEvents() -> [ClientLogEvent] {
        let formatter = ISO8601DateFormatter()
        do {
            let store = try OSLogStore(scope: .currentProcessIdentifier)
            let position = store.position(date: Date().addingTimeInterval(-snapshotWindow))
            var events: [ClientLogEvent] = []
            for entry in try store.getEntries(at: position) {
                guard let log = entry as? OSLogEntryLog,
                      log.subsystem.hasPrefix("com.getbored") else {
                    continue
                }
                events.append(ClientLogEvent(
                    timestamp: formatter.string(from: log.date),
                    level: levelName(log.level),
                    category: "\(log.subsystem)/\(log.category)",
                    message: log.composedMessage
                ))
            }
            return Array(events.suffix(maxEventsPerBatch))
        } catch {
            // No log access (old OS, store failure): report proceeds with an
            // empty batch so at least the reason + device context arrive.
            return []
        }
    }

    private static func levelName(_ level: OSLogEntryLog.Level) -> String {
        switch level {
        case .debug: return "debug"
        case .info: return "info"
        case .notice: return "notice"
        case .error: return "error"
        case .fault: return "fault"
        default: return "undefined"
        }
    }

    // MARK: - Upload

    /// POSTs one batch. Shared by the JS-triggered snapshot above and the
    /// MetricKit subscriber below.
    fileprivate static func sendBatch(reason: String,
                                      events: [ClientLogEvent],
                                      completion: ((Bool) -> Void)? = nil) {
        let request = ClientEventsRequest(
            reason: reason,
            context: currentContext(),
            events: events
        )
        guard let body = try? JSONEncoder().encode(request) else {
            completion?(false)
            return
        }
        APIClient.shared.send(
            .post,
            path: "/api/client-events",
            jsonBody: body,
            authenticated: true
        ) { result in
            switch result {
            case .success:
                completion?(true)
            case .failure:
                // Best-effort by design: offline, signed out, server down —
                // the report is simply lost, never surfaced as an error.
                completion?(false)
            }
        }
    }

    private static func currentContext() -> ClientContext {
        let info = Bundle.main.infoDictionary
        return ClientContext(
            appVersion: info?["CFBundleShortVersionString"] as? String ?? "unknown",
            build: info?["CFBundleVersion"] as? String ?? "unknown",
            iosVersion: UIDevice.current.systemVersion,
            deviceModel: hardwareModel()
        )
    }

    /// Hardware identifier ("iPhone14,4"), which — unlike UIDevice.model's
    /// generic "iPhone" — distinguishes the devices in a report stream.
    private static func hardwareModel() -> String {
        var systemInfo = utsname()
        uname(&systemInfo)
        return withUnsafeBytes(of: &systemInfo.machine) { buffer in
            let data = Data(buffer.prefix(while: { $0 != 0 }))
            return String(data: data, encoding: .utf8) ?? "unknown"
        }
    }
}

// ─── MetricKit: crashes and hangs, delivered by iOS itself ─────────────────

/// Apple's built-in diagnostic delivery: iOS hands the app crash and hang
/// reports as structured payloads (immediately on iOS 15+, else on next
/// launch). Registered once from AppDelegate.
///
/// Call flow:
///
///   AppDelegate.didFinishLaunching → MetricKitReporter.shared.start()
///           │
///           └── MXMetricManager.shared.add(self)   ← idempotent via `started`
///                   │
///                   ▼ (whenever iOS delivers diagnostics)
///           didReceive([MXDiagnosticPayload])
///                   └── each payload's JSON → one ClientLogEvent
///                           └── DiagnosticsModule.sendBatch("metrickit-diagnostic")
///                               (server truncates long payloads; the JSON's
///                                leading fields — crash type, signal — survive)
final class MetricKitReporter: NSObject, MXMetricManagerSubscriber {

    static let shared = MetricKitReporter()
    private var started = false

    func start() {
        guard !started else { return }
        started = true
        MXMetricManager.shared.add(self)
    }

    func didReceive(_ payloads: [MXDiagnosticPayload]) {
        let formatter = ISO8601DateFormatter()
        let events = payloads.map { payload in
            ClientLogEvent(
                timestamp: formatter.string(from: payload.timeStampEnd),
                level: "fault",
                category: "metrickit/diagnostic",
                message: String(data: payload.jsonRepresentation(), encoding: .utf8)
                    ?? "unencodable MetricKit payload"
            )
        }
        DiagnosticsModule.sendBatch(reason: "metrickit-diagnostic", events: events)
    }
}
