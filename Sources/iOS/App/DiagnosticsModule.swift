import Foundation
import MetricKit
import OSLog
import UIKit
import React
import GetBoredCore

private let logger = Logger(
    subsystem: GetBoredIdentifiers.Logging.iOSFilterApp,
    category: "Diagnostics"
)

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

    @objc static func requiresMainQueueSetup() -> Bool {
        logger.info("begin requiresMainQueueSetup")
        logger.info("end requiresMainQueueSetup: false")
        return false
    }

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
    ///           ├── request succeeds → resolve(["sent": true,  "events": N])
    ///           └── request fails    → resolve(["sent": false, "events": N])   ← never rejects
    @objc func reportRecentLogs(_ reason: String,
                                resolver resolve: @escaping RCTPromiseResolveBlock,
                                rejecter reject: @escaping RCTPromiseRejectBlock) {
        logger.info("begin reportRecentLogs: reason=\(reason, privacy: .public)")
        DispatchQueue.global(qos: .utility).async {
            let events = Self.collectRecentEvents()
            logger.info("reportRecentLogs: collected events=\(events.count, privacy: .public)")
            Self.sendBatch(reason: reason, events: events) { sent in
                if sent {
                    logger.info("end reportRecentLogs: accepted events=\(events.count, privacy: .public)")
                } else {
                    logger.warning("end reportRecentLogs: upload failed events=\(events.count, privacy: .public)")
                }
                resolve(["sent": sent, "events": events.count])
            }
        }
    }

    // MARK: - OSLogStore snapshot

    /// The app's own entries from the last [snapshotWindow], oldest first,
    /// capped to the NEWEST [maxEventsPerBatch] (the tail is where the error
    /// that triggered the report lives).
    private static func collectRecentEvents() -> [ClientLogEvent] {
        logger.info("begin collectRecentEvents")
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
            let recentEvents = Array(events.suffix(maxEventsPerBatch))
            logger.info("end collectRecentEvents: events=\(recentEvents.count, privacy: .public)")
            return recentEvents
        } catch {
            // No log access (old OS, store failure): report proceeds with an
            // empty batch so at least the reason + device context arrive.
            logger.warning("end collectRecentEvents: OSLogStore failed: \(error as NSError, privacy: .public)")
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
        logger.info("begin sendBatch: reason=\(reason, privacy: .public) events=\(events.count, privacy: .public)")
        let request = ClientEventsRequest(
            reason: reason,
            context: currentContext(),
            events: events
        )
        guard let body = try? JSONEncoder().encode(request) else {
            logger.error("end sendBatch: JSON encoding failed")
            completion?(false)
            return
        }
        Task {
            do {
                _ = try await APIClient.shared.send(
                    .post,
                    path: "/api/client-events",
                    jsonBody: body,
                    authenticated: true
                )
                logger.info("end sendBatch: batch accepted")
                completion?(true)
            } catch {
                // Best-effort by design: offline, signed out, server down —
                // the report is simply lost, never surfaced as an error.
                switch APIError.normalized(error) {
                case .network(let underlying), .decoding(let underlying):
                    logger.warning("end sendBatch: upload failed: \(underlying as NSError, privacy: .public)")
                case .server(let status):
                    logger.warning("end sendBatch: server status=\(status, privacy: .public)")
                case .signedOut:
                    logger.warning("end sendBatch: signedOut")
                case .subscriptionRequired:
                    logger.warning("end sendBatch: subscriptionRequired")
                }
                completion?(false)
            }
        }
    }

    private static func currentContext() -> ClientContext {
        logger.info("begin currentContext")
        let info = Bundle.main.infoDictionary
        let context = ClientContext(
            appVersion: info?["CFBundleShortVersionString"] as? String ?? "unknown",
            build: info?["CFBundleVersion"] as? String ?? "unknown",
            iosVersion: UIDevice.current.systemVersion,
            deviceModel: hardwareModel()
        )
        logger.info("end currentContext")
        return context
    }

    /// Hardware identifier ("iPhone14,4"), which — unlike UIDevice.model's
    /// generic "iPhone" — distinguishes the devices in a report stream.
    private static func hardwareModel() -> String {
        logger.info("begin hardwareModel")
        var systemInfo = utsname()
        uname(&systemInfo)
        let model = withUnsafeBytes(of: &systemInfo.machine) { buffer in
            let data = Data(buffer.prefix(while: { $0 != 0 }))
            return String(data: data, encoding: .utf8) ?? "unknown"
        }
        logger.info("end hardwareModel: model=\(model, privacy: .public)")
        return model
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
        logger.info("begin MetricKitReporter.start")
        guard !started else {
            logger.info("end MetricKitReporter.start: already started")
            return
        }
        started = true
        MXMetricManager.shared.add(self)
        logger.info("end MetricKitReporter.start: subscriber registered")
    }

    func didReceive(_ payloads: [MXDiagnosticPayload]) {
        logger.info("begin MetricKitReporter.didReceive: payloads=\(payloads.count, privacy: .public)")
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
        logger.info("end MetricKitReporter.didReceive: batch queued")
    }
}
