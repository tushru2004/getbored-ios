import Foundation
import NetworkExtension
import CloudKit
import React
import UIKit
import GetBoredCore

@objc(FilterStatus)
final class FilterStatusModule: NSObject {
    private let cloudContainer = CKContainer(identifier: GetBoredIdentifiers.CloudKit.containerIdentifier)
    private let deviceIDDefaultsKey = "com.getbored.ios.cloudkitDeviceID"

    #if DEBUG
    private let deviceRegistrationEnvironment = "debug"
    #else
    private let deviceRegistrationEnvironment = "production"
    #endif

    @objc static func requiresMainQueueSetup() -> Bool { false }

    @objc func current(_ resolve: @escaping RCTPromiseResolveBlock,
                       rejecter reject: @escaping RCTPromiseRejectBlock) {
        NEFilterManager.shared().loadFromPreferences { filterError in
            let filterEnabled: Bool? = filterError == nil ? NEFilterManager.shared().isEnabled : nil
            let filterErrorMsg = filterError?.localizedDescription

            self.cloudContainer.accountStatus { status, ckError in
                let icloudAvailable: Bool? = ckError == nil ? (status == .available) : nil
                let icloudErrorMsg = ckError?.localizedDescription

                let vm = KMPDecisionCoreAdapter.filterStatusViewModel(
                    filterEnabled: filterEnabled,
                    filterErrorMessage: filterErrorMsg,
                    icloudAvailable: icloudAvailable,
                    icloudErrorMessage: icloudErrorMsg
                )
                resolve(vm.toDictionary())
            }
        }
    }

    @objc func registerDevice(_ resolve: @escaping RCTPromiseResolveBlock,
                              rejecter reject: @escaping RCTPromiseRejectBlock) {
        // React Native calls this when the user taps Register/Refresh Registration.
        // Device registration should only touch CloudKit after iCloud is available.
        requireAvailableICloudAccount(rejecter: reject) {
            self.upsertDeviceRegistration(resolve, rejecter: reject)
        }
    }

    @objc func currentDeviceRegistration(_ resolve: @escaping RCTPromiseResolveBlock,
                                         rejecter reject: @escaping RCTPromiseRejectBlock) {
        guard let deviceID = loadExistingDeviceID() else {
            // No locally saved device ID means this app has not registered this install yet.
            resolve(registrationSnapshotDictionary(for: nil, registeredDeviceCount: 0))
            return
        }

        // A saved local device ID is only useful if we can read the matching CloudKit record.
        requireAvailableICloudAccount(rejecter: reject) {
            let recordID = CKRecord.ID(recordName: self.deviceRegistrationRecordName(for: deviceID))
            self.cloudContainer.privateCloudDatabase.fetch(withRecordID: recordID) { record, fetchError in
                if let fetchError {
                    if Self.isUnknownItemError(fetchError) {
                        resolve(self.registrationSnapshotDictionary(for: nil, registeredDeviceCount: 0))
                    } else {
                        reject("device_registration_fetch_failed", Self.cloudKitErrorMessage(fetchError), fetchError)
                    }
                    return
                }

                guard let record else {
                    resolve(self.registrationSnapshotDictionary(for: nil, registeredDeviceCount: 0))
                    return
                }

                guard let registration = DeviceRegistration(record: record) else {
                    reject("device_registration_decode_failed", "CloudKit device registration record is missing required fields", nil)
                    return
                }
                resolve(self.registrationSnapshotDictionary(for: registration, registeredDeviceCount: 1))
            }
        }
    }

    /// Runs work only when the iCloud account is usable; otherwise rejects the React Native promise.
    private func requireAvailableICloudAccount(
        rejecter reject: @escaping RCTPromiseRejectBlock,
        then work: @escaping () -> Void
    ) {
        // CloudKit accountStatus is asynchronous. This callback is the gate before any
        // CloudKit read/write that depends on the user's private iCloud database.
        cloudContainer.accountStatus { status, statusError in
            if let statusError {
                // The iCloud status check itself failed, so settle the JS promise as an error.
                reject("icloud_status_failed", Self.cloudKitErrorMessage(statusError), statusError)
                return
            }

            guard status == .available else {
                // iCloud answered, but this account cannot use the private CloudKit database.
                reject("icloud_unavailable", "iCloud account is not available", nil)
                return
            }

            // iCloud is available. Continue with the caller's CloudKit operation.
            work()
        }
    }

    private func upsertDeviceRegistration(_ resolve: @escaping RCTPromiseResolveBlock,
                                          rejecter reject: @escaping RCTPromiseRejectBlock) {
        let deviceID = loadOrCreateDeviceID()
        let registration = DeviceRegistration(
            id: deviceID,
            deviceName: UIDevice.current.name,
            deviceModel: UIDevice.current.model,
            systemVersion: UIDevice.current.systemVersion,
            appVersion: appVersionString(),
            lastSeenAt: Date(),
            buildConfiguration: deviceRegistrationEnvironment
        )

        let recordID = CKRecord.ID(recordName: deviceRegistrationRecordName(for: deviceID))
        let db = cloudContainer.privateCloudDatabase

        db.fetch(withRecordID: recordID) { record, fetchError in
            if let fetchError, !Self.isUnknownItemError(fetchError) {
                reject("device_registration_fetch_failed", Self.cloudKitErrorMessage(fetchError), fetchError)
                return
            }

            let registrationRecord = record ?? CKRecord(
                recordType: GetBoredIdentifiers.CloudKit.RecordType.deviceRegistration,
                recordID: recordID
            )

            registration.write(to: registrationRecord)
            db.save(registrationRecord) { _, saveError in
                if let saveError {
                    reject("device_registration_save_failed", Self.cloudKitErrorMessage(saveError), saveError)
                    return
                }
                resolve(self.registrationDictionary(for: registration, registeredDeviceCount: 1))
            }
        }
    }

    private static func isUnknownItemError(_ error: Error) -> Bool {
        guard let ckError = error as? CKError else { return false }
        return ckError.code == .unknownItem
    }

    private static func cloudKitErrorMessage(_ error: Error) -> String {
        guard let ckError = error as? CKError else {
            return error.localizedDescription
        }
        return "CloudKit \(cloudKitErrorName(ckError.code)) (code \(ckError.errorCode)): \(ckError.localizedDescription)"
    }

    private static func cloudKitErrorName(_ code: CKError.Code) -> String {
        switch code {
        case .internalError: return "internalError"
        case .partialFailure: return "partialFailure"
        case .networkUnavailable: return "networkUnavailable"
        case .networkFailure: return "networkFailure"
        case .badContainer: return "badContainer"
        case .serviceUnavailable: return "serviceUnavailable"
        case .requestRateLimited: return "requestRateLimited"
        case .missingEntitlement: return "missingEntitlement"
        case .notAuthenticated: return "notAuthenticated"
        case .permissionFailure: return "permissionFailure"
        case .unknownItem: return "unknownItem"
        case .invalidArguments: return "invalidArguments"
        case .serverRecordChanged: return "serverRecordChanged"
        case .serverRejectedRequest: return "serverRejectedRequest"
        case .quotaExceeded: return "quotaExceeded"
        case .limitExceeded: return "limitExceeded"
        case .zoneNotFound: return "zoneNotFound"
        default: return String(describing: code)
        }
    }

    private func loadOrCreateDeviceID() -> String {
        let defaults = UserDefaults.standard
        if let existing = defaults.string(forKey: deviceIDDefaultsKey), !existing.isEmpty {
            return existing
        }
        let created = UUID().uuidString
        defaults.set(created, forKey: deviceIDDefaultsKey)
        return created
    }

    private func loadExistingDeviceID() -> String? {
        let defaults = UserDefaults.standard
        guard let existing = defaults.string(forKey: deviceIDDefaultsKey), !existing.isEmpty else {
            return nil
        }
        return existing
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

    private func deviceRegistrationRecordName(for deviceID: String) -> String {
        GetBoredIdentifiers.CloudKit.RecordName.deviceRegistration(
            deviceID: deviceID,
            environment: deviceRegistrationEnvironment
        )
    }

    private func registrationDictionary(
        for entry: DeviceRegistration,
        registeredDeviceCount: Int
    ) -> [String: Any] {
        [
            "id": entry.id,
            "deviceName": entry.deviceName,
            "deviceModel": entry.deviceModel,
            "systemVersion": entry.systemVersion,
            "appVersion": entry.appVersion,
            "lastSeenAt": Self.iso8601Formatter.string(from: entry.lastSeenAt),
            "buildConfiguration": entry.buildConfiguration,
            "registeredDeviceCount": registeredDeviceCount,
        ]
    }

    private func registrationSnapshotDictionary(
        for entry: DeviceRegistration?,
        registeredDeviceCount: Int
    ) -> [String: Any] {
        guard let entry else {
            return [
                "isRegistered": false,
                "registration": NSNull(),
                "registeredDeviceCount": registeredDeviceCount,
            ]
        }

        return [
            "isRegistered": true,
            "registration": registrationDictionary(for: entry, registeredDeviceCount: registeredDeviceCount),
            "registeredDeviceCount": registeredDeviceCount,
        ]
    }

    private static let iso8601Formatter = ISO8601DateFormatter()
}

private struct DeviceRegistration {
    let id: String
    let deviceName: String
    let deviceModel: String
    let systemVersion: String
    let appVersion: String
    let lastSeenAt: Date
    let buildConfiguration: String

    init(
        id: String,
        deviceName: String,
        deviceModel: String,
        systemVersion: String,
        appVersion: String,
        lastSeenAt: Date,
        buildConfiguration: String
    ) {
        self.id = id
        self.deviceName = deviceName
        self.deviceModel = deviceModel
        self.systemVersion = systemVersion
        self.appVersion = appVersion
        self.lastSeenAt = lastSeenAt
        self.buildConfiguration = buildConfiguration
    }

    init?(record: CKRecord) {
        guard let id = record[GetBoredIdentifiers.CloudKit.Field.deviceID] as? String,
              let deviceName = record[GetBoredIdentifiers.CloudKit.Field.deviceName] as? String,
              let deviceModel = record[GetBoredIdentifiers.CloudKit.Field.deviceModel] as? String,
              let systemVersion = record[GetBoredIdentifiers.CloudKit.Field.systemVersion] as? String,
              let appVersion = record[GetBoredIdentifiers.CloudKit.Field.appVersion] as? String,
              let lastSeenAt = record[GetBoredIdentifiers.CloudKit.Field.lastSeenAt] as? Date,
              let buildConfiguration = record[GetBoredIdentifiers.CloudKit.Field.buildConfiguration] as? String else {
            return nil
        }

        self.init(
            id: id,
            deviceName: deviceName,
            deviceModel: deviceModel,
            systemVersion: systemVersion,
            appVersion: appVersion,
            lastSeenAt: lastSeenAt,
            buildConfiguration: buildConfiguration
        )
    }

    func write(to record: CKRecord) {
        record[GetBoredIdentifiers.CloudKit.Field.deviceID] = id as NSString
        record[GetBoredIdentifiers.CloudKit.Field.deviceName] = deviceName as NSString
        record[GetBoredIdentifiers.CloudKit.Field.deviceModel] = deviceModel as NSString
        record[GetBoredIdentifiers.CloudKit.Field.systemVersion] = systemVersion as NSString
        record[GetBoredIdentifiers.CloudKit.Field.appVersion] = appVersion as NSString
        record[GetBoredIdentifiers.CloudKit.Field.lastSeenAt] = lastSeenAt as NSDate
        record[GetBoredIdentifiers.CloudKit.Field.buildConfiguration] = buildConfiguration as NSString
        record[GetBoredIdentifiers.CloudKit.Field.updatedAt] = Date() as NSDate
    }
}

private extension GetBoredIdentifiers.CloudKit.RecordType {
    static let deviceRegistration = "DeviceRegistration"
}

private extension GetBoredIdentifiers.CloudKit.RecordName {
    static func deviceRegistration(deviceID: String, environment: String) -> String {
        "DeviceRegistration-\(deviceID)-\(environment)"
    }
}

private extension GetBoredIdentifiers.CloudKit.Field {
    static let deviceID = "deviceId"
    static let deviceName = "deviceName"
    static let deviceModel = "deviceModel"
    static let systemVersion = "systemVersion"
    static let appVersion = "appVersion"
    static let lastSeenAt = "lastSeenAt"
    static let buildConfiguration = "buildConfiguration"
}
