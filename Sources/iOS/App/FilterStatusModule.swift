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

    /// Custom zone for GetBored records. Unlike `_defaultZone`, custom zones
    /// support CKShare, atomic batches, and change tokens — required for
    /// future parent-child sharing of registrations and blocklists.
    private static let syncZoneID = CKRecordZone.ID(
        zoneName: "GetBoredSync",
        ownerName: CKCurrentUserDefaultName
    )

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
                let payload = vm.toDictionary()
                resolve(payload)
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
            let unregisteredSnapshot = registrationSnapshotDictionary(for: nil, registeredDeviceCount: 0)
            resolve(unregisteredSnapshot)
            return
        }

        // A saved local device ID is only useful if we can read the matching CloudKit record.
        requireAvailableICloudAccount(rejecter: reject) {
            let recordID = CKRecord.ID(
                recordName: self.deviceRegistrationRecordName(for: deviceID),
                zoneID: Self.syncZoneID
            )
            self.cloudContainer.privateCloudDatabase.fetch(withRecordID: recordID) { record, fetchError in
                if let fetchError {
                    if Self.isRecordNotFoundError(fetchError) {
                        let unregisteredSnapshot = self.registrationSnapshotDictionary(for: nil, registeredDeviceCount: 0)
                        resolve(unregisteredSnapshot)
                    } else {
                        reject("device_registration_fetch_failed", Self.cloudKitErrorMessage(fetchError), fetchError)
                    }
                    return
                }

                guard let record else {
                    let unregisteredSnapshot = self.registrationSnapshotDictionary(for: nil, registeredDeviceCount: 0)
                    resolve(unregisteredSnapshot)
                    return
                }

                guard let registration = DeviceRegistration(record: record) else {
                    reject("device_registration_decode_failed", "CloudKit device registration record is missing required fields", nil)
                    return
                }
                let registeredSnapshot = self.registrationSnapshotDictionary(for: registration, registeredDeviceCount: 1)
                resolve(registeredSnapshot)
            }
        }
    }

    // MARK: - Filter List Sync

    /// Fetches all `FilterList` records from CloudKit, applies the ones assigned
    /// to this device, and writes the merged rules to the shared App-Group store
    /// so the filter extension picks them up within its 5-second cache TTL.
    ///
    /// Call flow:
    ///
    ///   JS calls syncFilterLists()
    ///           │
    ///           ▼
    ///   requireAvailableICloudAccount(rejecter: reject) { ... }
    ///           │
    ///           ├── iCloud status check fails → reject(icloud_status_failed)
    ///           ├── account not available     → reject(icloud_unavailable)
    ///           │
    ///           └── IS available → calls the closure:
    ///                   │
    ///                   ▼
    ///               fetchAllFilterListRecords(resolve, rejecter: reject)
    ///                   │
    ///                   └── (CloudKit streams records back asynchronously)
    ///                           │
    ///                           ├── recordMatchedBlock × N  ← one call per record
    ///                           │
    ///                           └── queryResultBlock
    ///                                   ├── .failure(zoneNotFound/unknownItem) → resolve(nil)
    ///                                   ├── .failure(other error)              → reject(...)
    ///                                   └── .success → decodeAndApplyFilterLists(fetchedRecords)
    @objc func syncFilterLists(_ resolve: @escaping RCTPromiseResolveBlock,
                               rejecter reject: @escaping RCTPromiseRejectBlock) {
        requireAvailableICloudAccount(rejecter: reject) {
            self.fetchAllFilterListRecords(resolve, rejecter: reject)
        }
    }

    /// Returns the currently active filter rules from the shared App-Group store.
    /// Reads synchronously from UserDefaults — no CloudKit call required.
    @objc func loadActiveRules(_ resolve: RCTPromiseResolveBlock,
                               rejecter reject: RCTPromiseRejectBlock) {
        let store = IOSRuleStore.shared
        let entries = store.loadSiteRules().map { $0.url }
        resolve([
            "mode":        store.getMode(),
            "entries":     entries,
            "exceptions":  store.loadExceptions(),
            "allowedApps": store.loadAllowedApps(),
        ] as [String: Any])
    }

    /// Builds and submits a CloudKit query for all `FilterList` records in the GetBoredSync zone.
    ///
    /// Call flow:
    ///
    ///   syncFilterLists (after iCloud gate) calls fetchAllFilterListRecords()
    ///           │
    ///           ├── builds CKQuery(recordType: "FilterList", predicate: true)
    ///           ├── sets operation.zoneID = syncZoneID (GetBoredSync zone)
    ///           ├── configures recordMatchedBlock  ← accumulates records into fetchedRecords[]
    ///           ├── configures queryResultBlock    ← fires once when streaming is complete
    ///           └── db.add(operation)  ← submits to CloudKit, returns immediately
    ///                   │
    ///                   └── (CloudKit background thread calls back later)
    ///                           │
    ///                           ├── recordMatchedBlock(.success) → fetchedRecords.append(record)
    ///                           ├── recordMatchedBlock(.failure) → skip record (non-fatal)
    ///                           │
    ///                           └── queryResultBlock
    ///                                   ├── .failure(zoneNotFound/unknownItem)
    ///                                   │       └── resolve(nil)  ← no lists configured yet
    ///                                   ├── .failure(other) → reject(filter_list_fetch_failed)
    ///                                   └── .success → decodeAndApplyFilterLists(fetchedRecords)
    ///
    /// SCHEMA REQUIREMENT: The `FilterList` record type must have a queryable index
    /// deployed in CloudKit for NSPredicate(value: true) to succeed. Verify this in
    /// both the Development and Production CloudKit environments before shipping.
    private func fetchAllFilterListRecords(_ resolve: @escaping RCTPromiseResolveBlock,
                                           rejecter reject: @escaping RCTPromiseRejectBlock) {
        // SCHEMA REQUIREMENT: The `FilterList` record type must have a queryable index
        // deployed in CloudKit for NSPredicate(value: true) to succeed. Verify this in
        // both the Development and Production CloudKit environments before shipping.
        let query = CKQuery(recordType: "FilterList", predicate: NSPredicate(value: true))
        let operation = CKQueryOperation(query: query)
        operation.zoneID = CKRecordZone.default().zoneID

        var fetchedRecords: [CKRecord] = []

        operation.recordMatchedBlock = { _, result in
            switch result {
            case .success(let record):
                fetchedRecords.append(record)
            case .failure:
                // A single record failing to load is non-fatal — skip it and continue.
                break
            }
        }

        operation.queryResultBlock = { result in
            switch result {
            case .failure(let error):
                if Self.isRecordNotFoundError(error) {
                    // Zone or record type not found — admin has not configured any lists yet.
                    // Preserve existing filter rules rather than wiping them on a schema gap.
                    resolve(nil)
                } else {
                    reject("filter_list_fetch_failed", Self.cloudKitErrorMessage(error), error)
                }
            case .success:
                // TODO: handle queryCursor if list count ever exceeds 100
                self.decodeAndApplyFilterLists(from: fetchedRecords, resolve: resolve, rejecter: reject)
            }
        }

        cloudContainer.privateCloudDatabase.add(operation)
    }

    /// Decodes raw CKRecords, filters to this device's assigned+active lists, then applies them.
    ///
    /// Call flow:
    ///
    ///   fetchAllFilterListRecords → queryResultBlock(.success)
    ///           │
    ///           ▼
    ///   decodeAndApplyFilterLists(from: fetchedRecords)
    ///           │
    ///           ├── compactMap CloudFilterList(record:)  ← skips records with non-UUID names
    ///           │
    ///           ├── loadExistingDeviceID() == nil
    ///           │       └── device not yet registered → resolve(nil), preserve existing rules
    ///           │
    ///           └── deviceID present → recordName = "DeviceRegistration-<id>-<env>"
    ///                   │
    ///                   ├── filter: isActive AND assignedDeviceIds.contains(recordName)
    ///                   │
    ///                   ├── assignedActiveLists is empty
    ///                   │       └── no lists assigned to this device → resolve(nil), preserve rules
    ///                   │
    ///                   └── assignedActiveLists non-empty
    ///                           │
    ///                           ▼
    ///                       applyDecodedFilterLists(assignedActiveLists)
    private func decodeAndApplyFilterLists(
        from records: [CKRecord],
        resolve: @escaping RCTPromiseResolveBlock,
        rejecter reject: @escaping RCTPromiseRejectBlock
    ) {
        let allLists = records.compactMap { CloudFilterList(record: $0)?.filterList }

        guard let deviceID = loadExistingDeviceID() else {
            // Device not yet registered — preserve existing filter rules.
            resolve(nil)
            return
        }

        let recordName = deviceRegistrationRecordName(for: deviceID)
        let assignedActiveLists = allLists.filter { list in
            list.isActive && list.assignedDeviceIds.contains(recordName)
        }

        guard !assignedActiveLists.isEmpty else {
            // No lists are assigned+active for this device — preserve existing rules rather
            // than wiping them. The admin may not have configured this device yet, or all
            // assigned lists are temporarily inactive.
            resolve(nil)
            return
        }

        applyDecodedFilterLists(assignedActiveLists, resolve: resolve)
    }

    /// Merges the assigned FilterLists into a single policy snapshot and writes it to IOSRuleStore.
    ///
    /// Call flow:
    ///
    ///   decodeAndApplyFilterLists → applyDecodedFilterLists(assignedActiveLists)
    ///           │  (still on CloudKit callback thread)
    ///           │
    ///           ├── resolveEffectiveMode  ← whiteList wins if any list is whiteList
    ///           ├── orderedUnique(flatMap \.entries)     → merged domain blocklist/allowlist
    ///           ├── orderedUnique(flatMap \.exceptions)  → merged URL path exceptions
    ///           └── orderedUnique(flatMap \.allowedApps) → merged per-app bypasses
    ///                   │
    ///                   ▼
    ///               DispatchQueue.main.async  ← hop to main thread for UserDefaults write
    ///                   │
    ///                   ├── IOSRuleStore.shared.applyFilterListSnapshot(...)
    ///                   └── resolve(nil)  ← JS promise settles
    ///
    /// The main-queue hop is required because IOSRuleStore's UserDefaults cache
    /// (_cachedDefaults, _defaultsCacheTime) is mutated without synchronization.
    /// CloudKit callbacks arrive on background threads; writing from there races
    /// with any concurrent reader on the main thread.
    private func applyDecodedFilterLists(
        _ lists: [FilterList],
        resolve: @escaping RCTPromiseResolveBlock
    ) {
        let effectiveMode = resolveEffectiveMode(lists)
        let entries = orderedUnique(lists.flatMap(\.entries))
        let exceptions = orderedUnique(lists.flatMap(\.exceptions))
        let allowedApps = orderedUnique(lists.flatMap(\.allowedApps))

        DispatchQueue.main.async {
            IOSRuleStore.shared.applyFilterListSnapshot(
                mode: effectiveMode,
                entries: entries,
                exceptions: exceptions,
                allowedApps: allowedApps
            )
            resolve(nil)
        }
    }

    /// Determines the effective filter mode when multiple lists are merged.
    ///
    /// Call flow:
    ///
    ///   applyDecodedFilterLists calls resolveEffectiveMode(lists)
    ///           │
    ///           ├── any list has mode == .whiteList → return .whiteList
    ///           └── all lists are .blockSpecific (or lists is empty) → return .blockSpecific
    ///
    /// whiteList wins because it is strictly more permissive — a mixed assignment means
    /// the parent intended to allow everything except the listed entries, so blocking
    /// on top of that would silently override their intent.
    private func resolveEffectiveMode(_ lists: [FilterList]) -> FilterListMode {
        let hasWhiteList = lists.contains { $0.mode == .whiteList }
        return hasWhiteList ? .whiteList : .blockSpecific
    }

    /// Returns the input array with duplicates removed, preserving the first occurrence order.
    ///
    /// Call flow:
    ///
    ///   applyDecodedFilterLists calls orderedUnique(lists.flatMap(\.entries))
    ///           │
    ///           └── iterate strings:
    ///                   ├── seen.insert(string).inserted == true  → keep (first occurrence)
    ///                   └── seen.insert(string).inserted == false → drop (duplicate)
    ///
    /// Set.insert returns (inserted: Bool, ...) — inserted is true only on the first insertion,
    /// so filter keeps each string exactly once in its original order.
    private func orderedUnique(_ strings: [String]) -> [String] {
        var seen = Set<String>()
        return strings.filter { seen.insert($0).inserted }
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
        let recordID = CKRecord.ID(
            recordName: deviceRegistrationRecordName(for: deviceID),
            zoneID: Self.syncZoneID
        )
        let db = cloudContainer.privateCloudDatabase

        ensureSyncZoneExists(db: db, rejecter: reject) {
            self.fetchOrCreateRecord(recordID: recordID, db: db, rejecter: reject) { registrationRecord in
                registration.write(to: registrationRecord)
                self.saveRegistrationRecord(
                    registrationRecord,
                    registration: registration,
                    db: db,
                    resolve: resolve,
                    rejecter: reject
                )
            }
        }
    }

    /// Saves the GetBoredSync custom zone, succeeding whether the zone is new or already present.
    private func ensureSyncZoneExists(
        db: CKDatabase,
        rejecter reject: @escaping RCTPromiseRejectBlock,
        then next: @escaping () -> Void
    ) {
        // Saving a CKRecordZone is idempotent: it succeeds whether the zone is
        // new or already present.
        let zone = CKRecordZone(zoneID: Self.syncZoneID)
        db.save(zone) { _, zoneError in
            if let zoneError {
                reject("device_registration_zone_failed", Self.cloudKitErrorMessage(zoneError), zoneError)
                return
            }
            next()
        }
    }

    /// Fetches the existing registration record, or creates a fresh one if not found yet.
    private func fetchOrCreateRecord(
        recordID: CKRecord.ID,
        db: CKDatabase,
        rejecter reject: @escaping RCTPromiseRejectBlock,
        then next: @escaping (CKRecord) -> Void
    ) {
        db.fetch(withRecordID: recordID) { record, fetchError in
            if let fetchError, !Self.isRecordNotFoundError(fetchError) {
                reject("device_registration_fetch_failed", Self.cloudKitErrorMessage(fetchError), fetchError)
                return
            }
            let registrationRecord = record ?? CKRecord(
                recordType: GetBoredIdentifiers.CloudKit.RecordType.deviceRegistration,
                recordID: recordID
            )
            next(registrationRecord)
        }
    }

    /// Saves a fully-populated registration record and resolves the React Native promise on success.
    private func saveRegistrationRecord(
        _ record: CKRecord,
        registration: DeviceRegistration,
        db: CKDatabase,
        resolve: @escaping RCTPromiseResolveBlock,
        rejecter reject: @escaping RCTPromiseRejectBlock
    ) {
        db.save(record) { _, saveError in
            if let saveError {
                reject("device_registration_save_failed", Self.cloudKitErrorMessage(saveError), saveError)
                return
            }
            let registeredPayload = self.registrationDictionary(for: registration, registeredDeviceCount: 1)
            resolve(registeredPayload)
        }
    }

    /// True when a fetch failed only because the record — or the custom zone
    /// holding it — does not exist yet, i.e. this device has never registered.
    private static func isRecordNotFoundError(_ error: Error) -> Bool {
        guard let ckError = error as? CKError else { return false }
        return ckError.code == .unknownItem || ckError.code == .zoneNotFound
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
            "id": deviceRegistrationRecordName(for: entry.id),
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

    fileprivate static let iso8601Formatter = ISO8601DateFormatter()
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

// MARK: - CloudFilterList

/// Decodes a CloudKit `FilterList` record into the canonical `FilterList` model.
/// Returns `nil` if the record's `recordName` is not a valid UUID — the caller
/// should skip rather than fail the whole sync.
private struct CloudFilterList {
    let filterList: FilterList

    init?(record: CKRecord) {
        guard let id = UUID(uuidString: record.recordID.recordName) else { return nil }

        let name        = record["name"]        as? String ?? ""
        let description = record["description"] as? String ?? ""
        let entries     = record["entries"]      as? [String] ?? []
        let exceptions  = record["exceptions"]   as? [String] ?? []
        let allowedApps = record["allowedApps"]  as? [String] ?? []
        let assignedIds = Set(record["assignedDeviceIds"] as? [String] ?? [])
        let isActive    = ((record["isActive"] as? Int64) ?? 0) == 1
        let mode        = FilterListMode(rawValue: record["mode"] as? String ?? "") ?? .blockSpecific
        let createdAt   = Self.parseCreatedAt(record["createdAt"] as? String)

        self.filterList = FilterList(
            id: id, name: name, description: description,
            entries: entries, exceptions: exceptions, locations: [],
            allowedApps: allowedApps, isActive: isActive,
            createdAt: createdAt, mode: mode, assignedDeviceIds: assignedIds
        )
    }

    private static func parseCreatedAt(_ raw: String?) -> Date {
        guard let raw else { return Date() }
        return FilterStatusModule.iso8601Formatter.date(from: raw) ?? Date()
    }
}
