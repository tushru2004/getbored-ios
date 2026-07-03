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

    /// Reports the live filter + iCloud status to JS for the status screen.
    /// Two nested async checks; the second runs inside the first's completion.
    /// Always resolves (errors are surfaced as nil fields, never reject).
    ///
    /// Call flow:
    ///
    ///   JS calls current()
    ///           │
    ///           ▼
    ///   NEFilterManager.loadFromPreferences { filterError in ... }
    ///           │
    ///           ├── filterError != nil → filterEnabled = nil (unknown)
    ///           └── filterError == nil → filterEnabled = NEFilterManager.isEnabled
    ///                   │
    ///                   ▼
    ///           cloudContainer.accountStatus { status, ckError in ... }
    ///                   │
    ///                   ├── ckError != nil → icloudAvailable = nil (unknown)
    ///                   └── ckError == nil → icloudAvailable = (status == .available)
    ///                           │
    ///                           ▼
    ///                   KMPDecisionCoreAdapter.filterStatusViewModel(...)
    ///                           └── resolve(vm.toDictionary())  ← reject is never called
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

    /// Entry point for the Register / Refresh Registration button. Gates on
    /// iCloud availability, then upserts this device's registration record.
    ///
    /// Call flow:
    ///
    ///   JS calls registerDevice()
    ///           │
    ///           ▼
    ///   requireAvailableICloudAccount(rejecter: reject) { ... }
    ///           │
    ///           ├── status check fails → reject(icloud_status_failed), closure never runs
    ///           ├── not available      → reject(icloud_unavailable),  closure never runs
    ///           │
    ///           └── available → upsertDeviceRegistration(resolve, rejecter: reject)
    @objc func registerDevice(_ resolve: @escaping RCTPromiseResolveBlock,
                              rejecter reject: @escaping RCTPromiseRejectBlock) {
        // React Native calls this when the user taps Register/Refresh Registration.
        // Device registration should only touch CloudKit after iCloud is available.
        requireAvailableICloudAccount(rejecter: reject) {
            self.upsertDeviceRegistration(resolve, rejecter: reject)
        }
    }

    /// Reports whether this install already has a DeviceRegistration record in
    /// CloudKit, returning a snapshot dictionary for the status screen.
    ///
    /// Skips CloudKit entirely when no local device ID exists; otherwise the
    /// local ID is only trusted after its matching record is fetched.
    ///
    /// Call flow:
    ///
    ///   JS calls currentDeviceRegistration()
    ///           │
    ///           ▼
    ///   loadExistingDeviceID()  ← Keychain, then legacy UserDefaults
    ///           │
    ///           ├── nil → resolve(unregistered snapshot, count 0)  ← no CloudKit call
    ///           │
    ///           └── deviceID present → requireAvailableICloudAccount { ... }
    ///                   │       (status check fails / unavailable → reject(...))
    ///                   │
    ///                   ▼
    ///               privateCloudDatabase.fetch(DeviceRegistration-<id>-<env> in syncZone)
    ///                   │
    ///                   ├── fetchError
    ///                   │       ├── unknownItem / zoneNotFound → resolve(unregistered snapshot)
    ///                   │       └── other error               → reject(device_registration_fetch_failed)
    ///                   ├── record == nil                     → resolve(unregistered snapshot)
    ///                   ├── DeviceRegistration(record:) == nil → reject(device_registration_decode_failed)
    ///                   └── decoded                            → resolve(registered snapshot, count 1)
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
            "blockedApps": store.loadBlockedApps(),
        ] as [String: Any])
    }

    /// Builds and submits the first-page CloudKit query for all `FilterList` records
    /// in the default zone; runFilterListQuery follows pagination from there.
    ///
    /// NOTE: FilterList records live in the DEFAULT zone, not the GetBoredSync
    /// custom zone used for DeviceRegistration — see operation.zoneID below.
    ///
    /// Call flow:
    ///
    ///   syncFilterLists (after iCloud gate) calls fetchAllFilterListRecords()
    ///           │
    ///           ├── builds CKQuery(recordType: "FilterList", predicate: true)
    ///           ├── sets operation.zoneID = CKRecordZone.default().zoneID (default zone)
    ///           └── runFilterListQuery(operation, fetchedRecords: [])
    ///                   └── (see runFilterListQuery below for pagination + decode/apply)
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
        runFilterListQuery(operation, fetchedRecords: [], resolve: resolve, rejecter: reject)
    }

    /// Runs a `FilterList` query operation and follows CloudKit's pagination cursor
    /// until the whole result set is drained, before handing off to decode/apply.
    ///
    /// A device's assigned+active lists are now allowed to resolve to an empty
    /// snapshot (see decodeAndApplyFilterLists) whenever an admin deletion leaves
    /// none assigned. That makes a truncated page dangerous: without following the
    /// cursor, a device with >100 `FilterList` records in the container could see a
    /// spuriously empty first page and have its real rules wiped. Draining every
    /// page before deciding "no lists assigned" avoids that false negative.
    ///
    /// Call flow:
    ///
    ///   fetchAllFilterListRecords calls runFilterListQuery(operation, fetchedRecords: [])
    ///           │
    ///           ├── recordMatchedBlock × N  ← accumulates into this page's pageRecords
    ///           │
    ///           └── queryResultBlock
    ///                   ├── .failure(zoneNotFound/unknownItem) → resolve(nil)
    ///                   ├── .failure(other error)              → reject(filter_list_fetch_failed)
    ///                   ├── .success(cursor: non-nil)
    ///                   │       └── CKQueryOperation(cursor:) → recurse with fetchedRecords + pageRecords
    ///                   └── .success(cursor: nil)  ← last page
    ///                           └── decodeAndApplyFilterLists(fetchedRecords + pageRecords)
    private func runFilterListQuery(
        _ operation: CKQueryOperation,
        fetchedRecords: [CKRecord],
        resolve: @escaping RCTPromiseResolveBlock,
        rejecter reject: @escaping RCTPromiseRejectBlock
    ) {
        var pageRecords: [CKRecord] = []

        operation.recordMatchedBlock = { _, result in
            switch result {
            case .success(let record):
                pageRecords.append(record)
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
            case .success(let cursor):
                let allRecords = fetchedRecords + pageRecords
                guard let cursor else {
                    self.decodeAndApplyFilterLists(from: allRecords, resolve: resolve, rejecter: reject)
                    return
                }
                let nextOperation = CKQueryOperation(cursor: cursor)
                self.runFilterListQuery(nextOperation, fetchedRecords: allRecords, resolve: resolve, rejecter: reject)
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
    ///                   └── applyDecodedFilterLists(assignedActiveLists)
    ///                           ← always called, even when assignedActiveLists is empty, so an
    ///                             admin deleting/deactivating every list clears the device's
    ///                             rules instead of leaving a stale snapshot in place
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

        // No guard on emptiness here: if the admin deletes/deactivates every list
        // assigned to this device, assignedActiveLists is legitimately empty and
        // applyDecodedFilterLists([]) below writes an empty snapshot — clearing
        // stale entries instead of leaving a deleted list's rules stuck forever.
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
    ///           ├── orderedUnique(flatMap \.entries)      → merged domain blocklist/allowlist
    ///           ├── orderedUnique(flatMap \.exceptions)   → merged URL path exceptions
    ///           ├── orderedUnique(flatMap \.allowedApps)  → merged per-app bypasses
    ///           └── orderedUnique(flatMap \.blockedApps)  → merged per-app blocks
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
        let blockedApps = orderedUnique(lists.flatMap(\.blockedApps))

        DispatchQueue.main.async {
            IOSRuleStore.shared.applyFilterListSnapshot(
                mode: effectiveMode,
                entries: entries,
                exceptions: exceptions,
                allowedApps: allowedApps,
                blockedApps: blockedApps
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
    ///
    /// NOTE: v1 ships BLOCK MODE ONLY (the whitelist machinery was removed from this build).
    /// If this resolves to `.whiteList` — e.g. an older CloudKit FilterList predating the
    /// cutover — IOSRuleStore.loadFilterRules() defensively coerces it back to `.blockSpecific`
    /// when read (see decodedFilterMode() in IOSRuleStore.swift), so it never reaches the
    /// flow-inspection decision. This function is left as-is; the guard lives downstream.
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

    /// Creates or refreshes this device's DeviceRegistration record in the
    /// GetBoredSync custom zone, then resolves JS with the saved snapshot.
    ///
    /// Runs only after registerDevice's iCloud gate has passed. Three chained
    /// async CloudKit steps — each fires the next from its completion closure,
    /// and any failure rejects the JS promise without advancing the chain.
    ///
    /// Call flow:
    ///
    ///   upsertDeviceRegistration(resolve, rejecter: reject)
    ///           │
    ///           ├── loadOrCreateDeviceID()  ← Keychain → legacy UserDefaults → mint UUID
    ///           ├── builds DeviceRegistration snapshot of the current device
    ///           │
    ///           ▼
    ///   ensureSyncZoneExists(db:) { ... }
    ///           │       └── zone save fails → reject(device_registration_zone_failed)
    ///           │
    ///           ▼
    ///   fetchOrCreateRecord(recordID:db:) { registrationRecord in ... }
    ///           │       └── fetch fails (non not-found) → reject(device_registration_fetch_failed)
    ///           │
    ///           ├── registration.write(to: registrationRecord)  ← stamps fields + updatedAt
    ///           │
    ///           ▼
    ///   saveRegistrationRecord(...)
    ///           ├── save fails → reject(device_registration_save_failed)
    ///           └── save ok    → resolve(registered snapshot, count 1)
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

    /// Returns the stable per-device ID, creating one if needed.
    ///
    /// Lookup order:
    ///
    ///   1. Keychain  — survives app reinstall; preferred source of truth.
    ///   2. UserDefaults (legacy)  — devices registered before the Keychain
    ///      migration still have an ID here. Migrate it on first read so the
    ///      device keeps its existing CloudKit registration record.
    ///   3. Mint a new UUID — first run after a clean install.
    ///
    /// Call flow:
    ///
    ///   KeychainDeviceID.read()
    ///           │
    ///           ├── non-empty String → return (Keychain hit)
    ///           │
    ///           └── nil (Keychain miss)
    ///                   │
    ///                   ├── UserDefaults has legacy ID
    ///                   │       ├── KeychainDeviceID.write(legacy)  ← one-time migration
    ///                   │       └── return legacy
    ///                   │
    ///                   └── no legacy ID
    ///                           ├── UUID().uuidString
    ///                           ├── KeychainDeviceID.write(created)
    ///                           └── return created
    private func loadOrCreateDeviceID() -> String {
        if let existing = KeychainDeviceID.read(), !existing.isEmpty {
            return existing
        }

        // Migrate a pre-existing UserDefaults ID so already-registered devices
        // don't churn their CloudKit registration record.
        if let legacy = UserDefaults.standard.string(forKey: deviceIDDefaultsKey), !legacy.isEmpty {
            KeychainDeviceID.write(legacy)
            return legacy
        }

        let created = UUID().uuidString
        KeychainDeviceID.write(created)
        return created
    }

    /// Returns the device ID if one has already been established, or `nil` if
    /// this device has never completed registration.
    ///
    /// Checks the Keychain first (post-migration) and falls back to UserDefaults
    /// for devices registered before the Keychain migration was deployed.
    private func loadExistingDeviceID() -> String? {
        if let existing = KeychainDeviceID.read(), !existing.isEmpty {
            return existing
        }

        // Legacy fallback: a device registered before the Keychain migration.
        let legacy = UserDefaults.standard.string(forKey: deviceIDDefaultsKey)
        return legacy.flatMap { $0.isEmpty ? nil : $0 }
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

// FilterList record fields. The shared `mode`, `exceptions`, and `allowedApps`
// keys already live in GetBoredIdentifiers.CloudKit.Field (getbored-core); the
// remaining FilterList-only keys are declared locally because the consumed
// getbored-core v0.1.2 does not yet model the FilterList record type.
private extension GetBoredIdentifiers.CloudKit.Field {
    static let name = "name"
    static let listDescription = "description"
    static let entries = "entries"
    static let blockedApps = "blockedApps"
    static let assignedDeviceIds = "assignedDeviceIds"
    static let isActive = "isActive"
    static let createdAt = "createdAt"
}

// MARK: - CloudFilterList

/// Decodes a CloudKit `FilterList` record into the canonical `FilterList` model.
/// Returns `nil` if the record's `recordName` is not a valid UUID — the caller
/// should skip rather than fail the whole sync.
private struct CloudFilterList {
    let filterList: FilterList

    init?(record: CKRecord) {
        guard let id = UUID(uuidString: record.recordID.recordName) else { return nil }

        let name        = record[GetBoredIdentifiers.CloudKit.Field.name]            as? String ?? ""
        let description = record[GetBoredIdentifiers.CloudKit.Field.listDescription] as? String ?? ""
        let entries     = record[GetBoredIdentifiers.CloudKit.Field.entries]         as? [String] ?? []
        let exceptions  = record[GetBoredIdentifiers.CloudKit.Field.exceptions]      as? [String] ?? []
        let allowedApps = record[GetBoredIdentifiers.CloudKit.Field.allowedApps]     as? [String] ?? []
        let blockedApps = record[GetBoredIdentifiers.CloudKit.Field.blockedApps]     as? [String] ?? []
        let assignedIds = Set(record[GetBoredIdentifiers.CloudKit.Field.assignedDeviceIds] as? [String] ?? [])
        let isActive    = ((record[GetBoredIdentifiers.CloudKit.Field.isActive] as? Int64) ?? 0) == 1
        let mode        = FilterListMode(rawValue: record[GetBoredIdentifiers.CloudKit.Field.mode] as? String ?? "") ?? .blockSpecific
        let createdAt   = Self.parseCreatedAt(record[GetBoredIdentifiers.CloudKit.Field.createdAt] as? String)

        self.filterList = FilterList(
            id: id, name: name, description: description,
            entries: entries, exceptions: exceptions, locations: [],
            allowedApps: allowedApps, blockedApps: blockedApps, isActive: isActive,
            createdAt: createdAt, mode: mode, assignedDeviceIds: assignedIds
        )
    }

    private static func parseCreatedAt(_ raw: String?) -> Date {
        guard let raw else { return Date() }
        return FilterStatusModule.iso8601Formatter.date(from: raw) ?? Date()
    }
}
