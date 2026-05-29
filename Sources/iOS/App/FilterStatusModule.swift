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
    private let deviceRegistryRecordName = GetBoredIdentifiers.CloudKit.RecordName.deviceRegistryDebug
    #else
    private let deviceRegistryRecordName = GetBoredIdentifiers.CloudKit.RecordName.deviceRegistryProduction
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
        cloudContainer.accountStatus { [weak self] status, statusError in
            guard let self else { return }

            if let statusError {
                reject("icloud_status_failed", statusError.localizedDescription, statusError)
                return
            }

            guard status == .available else {
                reject("icloud_unavailable", "iCloud account is not available", nil)
                return
            }

            self.upsertDeviceRegistration(resolve, rejecter: reject)
        }
    }

    private func upsertDeviceRegistration(_ resolve: @escaping RCTPromiseResolveBlock,
                                          rejecter reject: @escaping RCTPromiseRejectBlock) {
        let deviceID = loadOrCreateDeviceID()
        let entry = CloudKitDeviceRegistryEntry(
            id: deviceID,
            deviceName: UIDevice.current.name,
            deviceModel: UIDevice.current.model,
            systemVersion: UIDevice.current.systemVersion,
            appVersion: appVersionString(),
            lastSeenAt: Date()
        )

        let recordID = CKRecord.ID(recordName: deviceRegistryRecordName)
        let db = cloudContainer.privateCloudDatabase

        db.fetch(withRecordID: recordID) { record, fetchError in
            if let fetchError, !Self.isUnknownItemError(fetchError) {
                reject("device_registry_fetch_failed", fetchError.localizedDescription, fetchError)
                return
            }

            let registryRecord = record ?? CKRecord(
                recordType: GetBoredIdentifiers.CloudKit.RecordType.deviceRegistry,
                recordID: recordID
            )

            do {
                let existing = try Self.decodeDeviceRegistry(from: registryRecord)
                let updated = CloudKitDeviceRegistryEntry.upserting(entry, into: existing)
                let data = try JSONEncoder().encode(updated)
                guard let json = String(data: data, encoding: .utf8) else {
                    reject("device_registry_encode_failed", "Could not encode device registry", nil)
                    return
                }

                registryRecord[GetBoredIdentifiers.CloudKit.Field.devicesJSON] = json as NSString
                registryRecord[GetBoredIdentifiers.CloudKit.Field.updatedAt] = Date() as NSDate

                db.save(registryRecord) { _, saveError in
                    if let saveError {
                        reject("device_registry_save_failed", saveError.localizedDescription, saveError)
                        return
                    }
                    resolve(self.registrationDictionary(for: entry, registeredDeviceCount: updated.count))
                }
            } catch {
                reject("device_registry_decode_failed", error.localizedDescription, error)
            }
        }
    }

    private static func decodeDeviceRegistry(from record: CKRecord) throws -> [CloudKitDeviceRegistryEntry] {
        guard let json = record[GetBoredIdentifiers.CloudKit.Field.devicesJSON] as? String,
              let data = json.data(using: .utf8) else {
            return []
        }
        return try JSONDecoder().decode([CloudKitDeviceRegistryEntry].self, from: data)
    }

    private static func isUnknownItemError(_ error: Error) -> Bool {
        guard let ckError = error as? CKError else { return false }
        return ckError.code == .unknownItem
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

    private func registrationDictionary(
        for entry: CloudKitDeviceRegistryEntry,
        registeredDeviceCount: Int
    ) -> [String: Any] {
        [
            "id": entry.id,
            "deviceName": entry.deviceName,
            "deviceModel": entry.deviceModel,
            "systemVersion": entry.systemVersion,
            "appVersion": entry.appVersion,
            "lastSeenAt": entry.lastSeenAt,
            "registeredDeviceCount": registeredDeviceCount,
        ]
    }
}
