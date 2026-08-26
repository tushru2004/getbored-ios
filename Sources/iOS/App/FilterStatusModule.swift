import Foundation
import NetworkExtension
import os.log
import React
import UIKit
import GetBoredCore

/// Errors logged here ride the remote-diagnostics pipeline: DiagnosticsModule
/// snapshots this subsystem's entries from OSLogStore and ships them to
/// /api/client-events, so a failed enable on any device is explained in the
/// server logs — provided the failure is actually WRITTEN here first.
private let logger = Logger(
    subsystem: GetBoredIdentifiers.Logging.iOSFilterApp,
    category: "FilterStatusModule"
)

/// React Native bridge for filter status, device registration, and policy sync.
///
/// This module talks to the GetBored REST API (`APIClient`) and the Keychain
/// (`KeychainStore`). Two identifiers matter: the session token (are we
/// signed in?) and the server-minted device id (has THIS install
/// registered?). Both live in the Keychain; the server mints and owns the
/// device id.
@objc(FilterStatus)
final class FilterStatusModule: NSObject {

    @objc static func requiresMainQueueSetup() -> Bool { false }

    /// Reports the live filter + sign-in status to JS for the status screen.
    /// Always resolves (errors are surfaced as nil fields, never reject).
    ///
    /// Call flow:
    ///
    ///   JS calls current()
    ///           │
    ///           ▼
    ///   NEFilterManager.loadFromPreferences { filterError in ... }
    ///           │
    ///           ├── filterError != nil → filterEnabled = nil, profileState = unknown
    ///           └── filterError == nil
    ///                   ├── providerConfiguration == nil → profileState = missing
    ///                   └── providerConfiguration != nil → profileState = installed
    ///                           └── filterEnabled = NEFilterManager.isEnabled
    ///                   │
    ///                   ▼
    ///           KMPDecisionCoreAdapter.filterStatusViewModel(
    ///               filterEnabled:, filterErrorMessage:,
    ///               icloudAvailable: nil, icloudErrorMessage: nil   ← iCloud is gone; fed nil
    ///           )                                                     only to satisfy Kotlin's
    ///                   │                                             existing signature
    ///                   ▼
    ///           resolve({filterState, filterLabel, profileState, signedIn})
    ///
    /// The Kotlin core still owns filter-state wording (active/inactive/unknown);
    /// its icloudState/icloudLabel outputs are discarded below rather than
    /// forwarded to JS — `signedIn` (a local Keychain check) replaces them.
    @objc func current(_ resolve: @escaping RCTPromiseResolveBlock,
                       rejecter reject: @escaping RCTPromiseRejectBlock) {
        let manager = NEFilterManager.shared()
        manager.loadFromPreferences { filterError in
            let filterEnabled: Bool? = filterError == nil ? manager.isEnabled : nil
            let filterErrorMsg = filterError?.localizedDescription
            let profileState: String
            if filterError != nil {
                profileState = "unknown"
            } else if manager.providerConfiguration == nil {
                profileState = "missing"
            } else {
                profileState = "installed"
            }

            let vm = KMPDecisionCoreAdapter.filterStatusViewModel(
                filterEnabled: filterEnabled,
                filterErrorMessage: filterErrorMsg,
                icloudAvailable: nil,
                icloudErrorMessage: nil
            )

            let payload: [String: Any] = [
                "filterState": vm.filterState,
                "filterLabel": vm.filterLabel,
                "profileState": profileState,
                "signedIn": self.isSignedIn(),
            ]
            resolve(payload)
        }
    }

    /// Entry point for the Register / Refresh Registration button. Creates this
    /// device's server-side row on first call, updates it on every later call.
    ///
    /// Call flow:
    ///
    ///   JS calls registerDevice()
    ///           │
    ///           ▼
    ///   KeychainStore.read(.serverDeviceID)
    ///           │
    ///           ├── nil        → createDevice(input)              ← POST /api/devices
    ///           └── existingID → updateDevice(existingID, input)  ← PUT /api/devices/{id}
    @objc func registerDevice(_ resolve: @escaping RCTPromiseResolveBlock,
                              rejecter reject: @escaping RCTPromiseRejectBlock) {
        let input = currentDeviceInput()
        guard let existingID = KeychainStore.read(.serverDeviceID) else {
            createDevice(input: input, resolve: resolve, rejecter: reject)
            return
        }
        updateDevice(id: existingID, input: input, resolve: resolve, rejecter: reject)
    }

    /// Registers a never-before-seen device: POSTs the device input, then saves
    /// the server-minted id to the Keychain so every later call becomes a PUT.
    ///
    /// Call flow:
    ///
    ///   registerDevice (no stored id) or updateDevice (404 self-heal) call createDevice(input)
    ///           │
    ///           ▼
    ///   APIClient.shared.request(Device.self, .post, "/api/devices", jsonBody: input)
    ///           │
    ///           ├── returns device → KeychainStore.write(device.id, for: .serverDeviceID)
    ///           │                    resolve(deviceDictionary(device))
    ///           └── throws error   → reject(for: error, rejecter: reject)
    private func createDevice(input: DeviceInput,
                              resolve: @escaping RCTPromiseResolveBlock,
                              rejecter reject: @escaping RCTPromiseRejectBlock) {
        guard let body = try? JSONEncoder().encode(input) else {
            reject(RejectCode.server, "Failed to encode device registration payload.", nil)
            return
        }
        Task {
            do {
                let device = try await APIClient.shared.request(
                    Device.self, method: .post, path: "/api/devices", jsonBody: body
                )
                KeychainStore.write(device.id, for: .serverDeviceID)
                resolve(self.deviceDictionary(device))
            } catch {
                self.reject(for: APIError.normalized(error), rejecter: reject)
            }
        }
    }

    /// Re-registers an already-known device: PUTs the fresh device input to its
    /// existing server row (name/model/appVersion may have changed since the
    /// last register call — e.g. an app update bumped `appVersion`).
    ///
    /// A 404 means the server row is gone (e.g. an admin deleted it) even though
    /// this install still remembers an id for it. Self-heals by forgetting the
    /// stale id and re-registering from scratch, exactly like a fresh install.
    ///
    /// Call flow:
    ///
    ///   registerDevice (stored id present) calls updateDevice(id, input)
    ///           │
    ///           ▼
    ///   APIClient.shared.request(Device.self, .put, "/api/devices/{id}", jsonBody: input)
    ///           │
    ///           ├── returns device      → resolve(deviceDictionary(device))
    ///           ├── throws .server(404) → KeychainStore.delete(.serverDeviceID)
    ///           │                           createDevice(input)  ← self-heal, retries as new
    ///           └── throws other error  → reject(for: error, rejecter: reject)
    private func updateDevice(id: String, input: DeviceInput,
                              resolve: @escaping RCTPromiseResolveBlock,
                              rejecter reject: @escaping RCTPromiseRejectBlock) {
        guard let body = try? JSONEncoder().encode(input) else {
            reject(RejectCode.server, "Failed to encode device registration payload.", nil)
            return
        }
        Task {
            do {
                let device = try await APIClient.shared.request(
                    Device.self, method: .put, path: "/api/devices/\(id)", jsonBody: body
                )
                resolve(self.deviceDictionary(device))
            } catch APIError.server(let status) where status == 404 {
                KeychainStore.delete(.serverDeviceID)
                self.createDevice(input: input, resolve: resolve, rejecter: reject)
            } catch {
                self.reject(for: APIError.normalized(error), rejecter: reject)
            }
        }
    }

    /// Reports whether this install already has a server-side device row,
    /// returning a snapshot dictionary for the status screen.
    ///
    /// Skips the network entirely when no server device id is stored yet.
    ///
    /// Call flow:
    ///
    ///   JS calls currentDeviceRegistration()
    ///           │
    ///           ▼
    ///   KeychainStore.read(.serverDeviceID)
    ///           │
    ///           ├── nil → resolve(unregisteredSnapshotDictionary())  ← no network call
    ///           │
    ///           └── deviceID present → GET /api/devices/{deviceID}
    ///                   │
    ///                   ├── returns device      → resolve(registeredSnapshotDictionary(device))
    ///                   ├── throws .server(404) → KeychainStore.delete(.serverDeviceID)
    ///                   │                          resolve(unregisteredSnapshotDictionary())
    ///                   └── throws other error  → reject(for: error, rejecter: reject)
    @objc func currentDeviceRegistration(_ resolve: @escaping RCTPromiseResolveBlock,
                                         rejecter reject: @escaping RCTPromiseRejectBlock) {
        guard let deviceID = KeychainStore.read(.serverDeviceID) else {
            resolve(unregisteredSnapshotDictionary())
            return
        }

        Task {
            do {
                let device = try await APIClient.shared.request(
                    Device.self, method: .get, path: "/api/devices/\(deviceID)"
                )
                resolve(self.registeredSnapshotDictionary(device))
            } catch APIError.server(let status) where status == 404 {
                KeychainStore.delete(.serverDeviceID)
                resolve(self.unregisteredSnapshotDictionary())
            } catch {
                self.reject(for: APIError.normalized(error), rejecter: reject)
            }
        }
    }

    /// Turns the content filter on from inside the app (the "Turn Filtering
    /// On" hero button) instead of sending the user to Settings. Saving the
    /// configuration makes iOS raise its own consent prompt when needed;
    /// on this app's already-configured devices it re-enables silently.
    ///
    /// Call flow:
    ///
    ///   NEFilterManager.loadFromPreferences
    ///           │
    ///           ├── load error → reject(SERVER)
    ///           └── ok
    ///                ├── no providerConfiguration yet → create one (filterSockets)
    ///                ├── isEnabled = true
    ///                ▼
    ///           saveToPreferences
    ///                ├── save error (incl. user denying the consent prompt) → reject(SERVER)
    ///                └── ok → resolve(nil)   ← caller re-reads current() for the new state
    @objc func enableFilter(_ resolve: @escaping RCTPromiseResolveBlock,
                            rejecter reject: @escaping RCTPromiseRejectBlock) {
        logger.info("begin enableFilter")
        let manager = NEFilterManager.shared()
        manager.loadFromPreferences { loadError in
            if let loadError {
                logger.error("end enableFilter: loadFromPreferences failed: \(loadError as NSError, privacy: .public)")
                reject("SERVER", loadError.localizedDescription, loadError)
                return
            }
            if manager.providerConfiguration == nil {
                let configuration = NEFilterProviderConfiguration()
                configuration.filterSockets = true
                manager.providerConfiguration = configuration
            }
            manager.localizedDescription = "GetBored"
            manager.isEnabled = true
            manager.saveToPreferences { saveError in
                if let saveError {
                    logger.error("end enableFilter: saveToPreferences failed: \(saveError as NSError, privacy: .public)")
                    reject("SERVER", saveError.localizedDescription, saveError)
                    return
                }
                logger.info("end enableFilter: configuration saved, filter enabled")
                resolve(nil)
            }
        }
    }

    /// Requests a short-lived, account-scoped customer-profile URL and opens
    /// it in the system browser. The browser download is deliberate: iOS does
    /// not let a third-party app silently install a configuration profile, so
    /// the customer completes Apple's consent flow in Settings.
    @objc func downloadProfile(_ resolve: @escaping RCTPromiseResolveBlock,
                               rejecter reject: @escaping RCTPromiseRejectBlock) {
        logger.info("begin downloadProfile")
        Task {
            do {
                let response = try await APIClient.shared.request(
                    ProfileDownloadResponse.self,
                    method: .post,
                    path: "/api/profile-downloads"
                )
                guard let url = URL(string: response.downloadUrl),
                      url.scheme == "https" else {
                    logger.error("end downloadProfile: server returned an invalid HTTPS URL")
                    reject(RejectCode.server, "The profile download link was invalid.", nil)
                    return
                }

                let opened = await UIApplication.shared.open(url, options: [:])
                if opened {
                    logger.info("end downloadProfile: opened profile URL")
                    resolve(nil)
                } else {
                    logger.error("end downloadProfile: iOS could not open profile URL")
                    reject(RejectCode.server, "Could not open the profile download.", nil)
                }
            } catch APIError.server(let status) where status == 409 {
                logger.warning("end downloadProfile: administrator has not configured a profile password")
                reject(
                    RejectCode.server,
                    "Your protection profile is not ready. Contact GetBored Support.",
                    nil
                )
            } catch {
                logger.error("end downloadProfile: ticket request failed")
                self.reject(for: APIError.normalized(error), rejecter: reject)
            }
        }
    }

    // MARK: - Filter List Sync

    /// Pulls this device's already-merged policy from the server and writes it
    /// to the shared App-Group store so the filter extension picks it up within
    /// its 5-second cache TTL. Merging (whitelist-wins, ordered-unique across
    /// assigned lists) now happens server-side — see `GET /api/policy`.
    ///
    /// Call flow:
    ///
    ///   JS calls syncFilterLists()
    ///           │
    ///           ▼
    ///   KeychainStore.read(.serverDeviceID)
    ///           │
    ///           ├── nil, signed in  → reject(NOT_REGISTERED)
    ///           ├── nil, signed out → reject(SIGNED_OUT)
    ///           │
    ///           └── deviceID present → GET /api/policy?deviceId=<deviceID>
    ///                   │
    ///                   ├── returns snapshot
    ///                   │       └── MainActor.run
    ///                   │               ├── IOSRuleStore.shared.applyFilterListSnapshot(...)
    ///                   │               └── resolve({sites, exceptions, allowedApps, blockedApps})
    ///                   │
    ///                   └── throws error → reject(for: error, rejecter: reject)
    ///
    /// An empty snapshot (all arrays empty) is a VALID response — it means the
    /// admin unassigned every list — and is applied exactly like a populated
    /// one, clearing the phone's rules instead of leaving a stale snapshot.
    @objc func syncFilterLists(_ resolve: @escaping RCTPromiseResolveBlock,
                               rejecter reject: @escaping RCTPromiseRejectBlock) {
        guard let deviceID = KeychainStore.read(.serverDeviceID) else {
            if isSignedIn() {
                reject(RejectCode.notRegistered, "This device has not registered yet.", nil)
            } else {
                reject(RejectCode.signedOut, "You're signed out.", nil)
            }
            return
        }

        let query = [URLQueryItem(name: "deviceId", value: deviceID)]
        Task {
            do {
                let snapshot = try await APIClient.shared.request(
                    PolicySnapshot.self, method: .get, path: "/api/policy", query: query
                )
                await MainActor.run {
                    IOSRuleStore.shared.applyFilterListSnapshot(
                        mode: snapshot.filterMode,
                        entries: snapshot.entries,
                        exceptions: snapshot.exceptions,
                        allowedApps: snapshot.allowedApps,
                        blockedApps: snapshot.blockedApps
                    )
                    // Resolve what was just applied so the UI can say
                    // "12 sites blocked · synced 4:32 PM" instead of a bare
                    // green pill — the snapshot is in hand, counting is free.
                    resolve([
                        "sites": snapshot.entries.count,
                        "exceptions": snapshot.exceptions.count,
                        "allowedApps": snapshot.allowedApps.count,
                        "blockedApps": snapshot.blockedApps.count,
                    ])
                }
            } catch {
                self.reject(for: APIError.normalized(error), rejecter: reject)
            }
        }
    }

    /// Returns the currently active filter rules from the shared App-Group store.
    /// Reads synchronously from UserDefaults — no network call required.
    @objc func loadActiveRules(_ resolve: RCTPromiseResolveBlock,
                               rejecter reject: RCTPromiseRejectBlock) {
        let store = IOSRuleStore.shared
        let entries = store.loadSiteRules().map { $0.url }
        resolve([
            "mode":        store.getMode(),
            "entries":     entries,
            "exceptions":  store.loadExceptions(),
            "allowedApps": store.loadAllowedApps(),
            "blockedApps": store.loadBlockedApps(),
        ] as [String: Any])
    }

    // MARK: - Shared error mapping

    /// Maps a failed API call onto the JS reject-code contract shared by every
    /// method in this file (the JS side mirrors these four codes, plus
    /// `syncFilterLists`'s own `NOT_REGISTERED`).
    ///
    /// Call flow:
    ///
    ///   any caught APIClient error calls reject(for: error, rejecter:)
    ///           │
    ///           ├── .signedOut            → reject(SIGNED_OUT)          ← existing rules kept as-is
    ///           ├── .subscriptionRequired → DispatchQueue.main.async
    ///           │                               ├── IOSRuleStore.shared.applyFilterListSnapshot(empty)
    ///           │                               │       ← "lapse stops filtering" product decision
    ///           │                               └── reject(SUBSCRIPTION_REQUIRED)  ← fires AFTER the
    ///           │                                     snapshot is applied, not before (see below)
    ///           ├── .network              → reject(NETWORK)
    ///           └── .server, .decoding     → reject(SERVER)
    ///
    /// subscriptionRequired's reject call is nested INSIDE the main.async block
    /// (rather than fired immediately before scheduling it) so that if JS reacts
    /// to the rejection by re-reading rules (e.g. `loadActiveRules()`), it can
    /// never observe the pre-lapse rules mid-clear — "FIRST apply, THEN reject"
    /// is an ordering guarantee, not just a comment.
    private func reject(for error: APIError, rejecter reject: @escaping RCTPromiseRejectBlock) {
        switch error {
        case .signedOut:
            reject(RejectCode.signedOut, "You're signed out.", error)

        case .subscriptionRequired:
            DispatchQueue.main.async {
                IOSRuleStore.shared.applyFilterListSnapshot(
                    mode: .blockSpecific,
                    entries: [],
                    exceptions: [],
                    allowedApps: [],
                    blockedApps: []
                )
                reject(RejectCode.subscriptionRequired, "Your subscription has lapsed.", error)
            }

        case .network(let underlying):
            reject(RejectCode.network, underlying.localizedDescription, error)

        case .server(let status):
            reject(RejectCode.server, "Server returned status \(status).", error)

        case .decoding(let underlying):
            reject(RejectCode.server, "Failed to decode server response: \(underlying.localizedDescription)", error)
        }
    }

    // MARK: - Device details

    /// Whether a session token is present in the Keychain. This is a local
    /// presence check only — sessions are server-revocable, so a stored token
    /// can be rejected by the server at any time; that case surfaces as
    /// `APIError.signedOut` from an actual request, handled in `reject(for:)`.
    private func isSignedIn() -> Bool {
        KeychainStore.read(.sessionToken) != nil
    }

    /// Builds the `DeviceInput` sent on every register/re-register call. The
    /// API only has three free-text fields — `name`, `model`, `appVersion` —
    /// so system details without fields of their own (system version,
    /// debug/production build configuration) are folded into `model`
    /// (see `modelDescription()`) instead of being dropped.
    private func currentDeviceInput() -> DeviceInput {
        DeviceInput(
            name: UIDevice.current.name,
            model: modelDescription(),
            appVersion: appVersionString()
        )
    }

    /// Hardware identifier + iOS version as one free-text string, e.g.
    /// "iPhone11,8 · iOS 18.2". `UIDevice.current.model` alone only reports the
    /// generic family name ("iPhone"), not the specific hardware generation.
    private func modelDescription() -> String {
        "\(hardwareModelIdentifier()) · iOS \(UIDevice.current.systemVersion)"
    }

    /// Reads the raw hardware identifier (e.g. "iPhone11,8") via `uname()`.
    private func hardwareModelIdentifier() -> String {
        var systemInfo = utsname()
        uname(&systemInfo)
        return withUnsafePointer(to: &systemInfo.machine) {
            $0.withMemoryRebound(to: CChar.self, capacity: 1) {
                String(cString: $0)
            }
        }
    }

    private func appVersionString() -> String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String

        switch (version, build) {
        case let (version?, build?) where !version.isEmpty && !build.isEmpty:
            return "\(version) (\(build))"
        case let (version?, _) where !version.isEmpty:
            return version
        case let (_, build?) where !build.isEmpty:
            return build
        default:
            return "unknown"
        }
    }

    /// Bridges an optional server field to the Objective-C-visible `NSNull`
    /// sentinel RN promises expect for "explicitly absent" — e.g. `lastSeenAt`
    /// is null for every device until its first `GET /api/policy` heartbeat
    /// (see the `Device` struct's doc comment) — instead of silently dropping
    /// the key or boxing a Swift `Optional` the JS side can't parse as null.
    private func jsonValue(_ string: String?) -> Any {
        guard let string else { return NSNull() }
        return string
    }

    private func deviceDictionary(_ device: Device) -> [String: Any] {
        [
            "id": device.id,
            "name": jsonValue(device.name),
            "model": jsonValue(device.model),
            "appVersion": jsonValue(device.appVersion),
            "lastSeenAt": jsonValue(device.lastSeenAt),
            "createdAt": device.createdAt,
        ]
    }

    private func unregisteredSnapshotDictionary() -> [String: Any] {
        [
            "isRegistered": false,
            "registration": NSNull(),
        ]
    }

    private func registeredSnapshotDictionary(_ device: Device) -> [String: Any] {
        [
            "isRegistered": true,
            "registration": deviceDictionary(device),
        ]
    }
}

/// JS-facing reject codes shared by every method in this file. Centralized so
/// "SIGNED_OUT" (used both by `reject(for:)`'s APIError mapping and by
/// `syncFilterLists`'s own no-device-id guard) can't drift into two different
/// literal strings by accident.
private enum RejectCode {
    static let signedOut = "SIGNED_OUT"
    static let subscriptionRequired = "SUBSCRIPTION_REQUIRED"
    static let network = "NETWORK"
    static let server = "SERVER"
    static let notRegistered = "NOT_REGISTERED"
}

/// Body for `POST /api/devices` and `PUT /api/devices/{id}`. Field names match
/// the wire format exactly, so no custom `CodingKeys` are needed.
private struct DeviceInput: Encodable {
    let name: String
    let model: String
    let appVersion: String
}

/// Decoded response from `POST`/`PUT`/`GET` on `/api/devices/...`. Mirrors the
/// backend's `Device` model exactly: only `id`/`createdAt` are guaranteed
/// non-null. `name`/`model`/`appVersion` are optional because `DeviceInput`
/// itself allows omitting them server-side; `lastSeenAt` is null for every
/// device until its first `GET /api/policy` heartbeat stamps it (the B4
/// "heartbeat for free" design — POST/PUT never set it). Decoding these as
/// non-optional `String` would throw on that very first registration
/// response, silently skipping the Keychain write of the new device id.
///
/// `lastSeenAt`/`createdAt` are passed through to JS as opaque ISO-8601
/// strings — nothing on the native side parses them, so they are not typed
/// as `Date`.
private struct Device: Decodable {
    let id: String
    let name: String?
    let model: String?
    let appVersion: String?
    let lastSeenAt: String?
    let createdAt: String
}

/// Response from `POST /api/profile-downloads`. The expiry is intentionally
/// omitted: the native app only needs the validated HTTPS URL; the backend
/// owns ticket lifetime and Safari owns the subsequent download.
private struct ProfileDownloadResponse: Decodable {
    let downloadUrl: String
}

/// Decoded response from `GET /api/policy?deviceId=`. The server also sends
/// `policySchemaVersion`, `deviceId`, and `generatedAt`, but nothing here
/// consumes them, so they are omitted — Decodable synthesis ignores JSON keys
/// with no matching property.
private struct PolicySnapshot: Decodable {
    let filterMode: FilterListMode
    let entries: [String]
    let exceptions: [String]
    let allowedApps: [String]
    let blockedApps: [String]
}
