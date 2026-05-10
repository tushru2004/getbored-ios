import Foundation
import CoreLocation
import os.log

class LocationBlockingManager: NSObject, ObservableObject, CLLocationManagerDelegate {
    static let shared = LocationBlockingManager()

    private let locationManager = CLLocationManager()
    private let logger = Logger(subsystem: GetBoredIdentifiers.Logging.iOSFilterApp, category: "LocationBlocking")

    @Published var permissionStatus: CLAuthorizationStatus = .notDetermined
    @Published var activeZoneNames: Set<String> = []
    @Published var monitoredRegionCount: Int = 0

    /// Stores the decoded location-enabled filter lists (kept in memory for recalculation)
    private var locationLists: [FilterList] = []

    /// Tracks which region identifiers the device is currently inside
    private var enteredRegionIDs: Set<String> = []

    private let appGroupIdentifier = GetBoredIdentifiers.AppGroup.iosAdvanceWhitelist
    private let lockdownKey = "location_permission_denied_lockdown"
    private let persistedListsKey = "location_filter_lists"
    private let persistedRegionIDsKey = "location_entered_region_ids"

    private override init() {
        super.init()
        locationManager.delegate = self
        locationManager.allowsBackgroundLocationUpdates = true
        permissionStatus = locationManager.authorizationStatus
        restorePersistedState()

        // Resume significant location monitoring if we have persisted location lists.
        // This ensures cell-tower-based background wake-ups continue after app kill.
        if !locationLists.isEmpty {
            locationManager.startMonitoringSignificantLocationChanges()
        }
    }

    // MARK: - Persistence (survives app kill / background wake)

    /// Persists locationLists to app group UserDefaults so background geofence
    /// events can recalculate entries without a CloudKit round-trip.
    /// Stored in the app group container — not accessible to the user.
    private func persistState() {
        let defaults = UserDefaults(suiteName: appGroupIdentifier)
        if let data = try? JSONEncoder().encode(locationLists) {
            defaults?.set(data, forKey: persistedListsKey)
        }
        defaults?.set(Array(enteredRegionIDs), forKey: persistedRegionIDsKey)
        defaults?.synchronize()
    }

    private func restorePersistedState() {
        let defaults = UserDefaults(suiteName: appGroupIdentifier)
        if let data = defaults?.data(forKey: persistedListsKey),
           let lists = try? JSONDecoder().decode([FilterList].self, from: data) {
            locationLists = lists
            logger.info("Restored \(lists.count) persisted location lists")
        }
        if let ids = defaults?.stringArray(forKey: persistedRegionIDsKey) {
            enteredRegionIDs = Set(ids)
            logger.info("Restored \(ids.count) persisted entered region IDs")
        }
    }

    // MARK: - Permissions

    func requestPermissions() {
        locationManager.requestAlwaysAuthorization()
    }

    // MARK: - Geofence Management

    /// Updates geofences from location-enabled filter lists.
    /// Call this after syncing filter lists from CloudKit.
    func updateGeofences(lists: [FilterList]) {
        locationLists = lists.filter { !$0.locations.isEmpty && $0.isActive }

        // Tell the filter extension whether location lists are configured,
        // so it doesn't trigger no-entries lockdown when outside all geofences.
        // TODO: Location feature not yet ported to IOSRuleStore on rebuild branch

        // Auto-request location permission if we have geofences to monitor
        // and permission hasn't been requested yet.
        if !locationLists.isEmpty && locationManager.authorizationStatus == .notDetermined {
            logger.info("Requesting location permission for geofence monitoring")
            locationManager.requestAlwaysAuthorization()
        }

        updateLocationLockdownFlag()

        // Remove all existing monitored regions
        for region in locationManager.monitoredRegions {
            locationManager.stopMonitoring(for: region)
        }

        // Register new geofences (iOS limit: 20 regions)
        var regionCount = 0
        for list in locationLists {
            for location in list.locations {
                guard regionCount < 20 else {
                    logger.warning("Geofence limit reached (20). Some locations will not be monitored.")
                    break
                }

                let identifier = "\(list.id.uuidString)|\(location.id.uuidString)"
                let region = CLCircularRegion(
                    center: CLLocationCoordinate2D(latitude: location.latitude, longitude: location.longitude),
                    radius: max(location.radiusMeters, 100),
                    identifier: identifier
                )
                region.notifyOnEntry = true
                region.notifyOnExit = true

                locationManager.startMonitoring(for: region)
                regionCount += 1
                logger.info("Monitoring geofence: \(location.name) (\(identifier))")
            }
            if regionCount >= 20 { break }
        }

        monitoredRegionCount = regionCount

        if regionCount > 0 {
            // Request a fresh location fix so the system can determine geofence state.
            // Without this, requestState(for:) may return .unknown on fresh installs
            // because no recent GPS coordinate is available.
            locationManager.requestLocation()

            // Use significant location changes as a backup for geofence exit detection.
            // iOS background geofence monitoring uses cell/WiFi positioning (~500m accuracy),
            // which is unreliable for small (100m) geofences. Significant location changes
            // deliver periodic wake-ups on cell tower changes, letting didUpdateLocations
            // re-request state for all regions and catch exits the native monitoring missed.
            locationManager.startMonitoringSignificantLocationChanges()
        } else {
            locationManager.stopMonitoringSignificantLocationChanges()
        }

        persistState()

        // Recalculate effective entries so that removed location lists
        // have their entries cleared from UserDefaults immediately.
        recalculateEffectiveEntries()

        // Request state for all monitored regions to handle app launch inside a geofence
        for region in locationManager.monitoredRegions {
            locationManager.requestState(for: region)
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        logger.info("Location fix received (\(locations.last?.coordinate.latitude ?? 0), \(locations.last?.coordinate.longitude ?? 0)) — re-checking geofence state")
        // Re-request state for all regions now that we have a fresh location fix
        for region in locationManager.monitoredRegions {
            locationManager.requestState(for: region)
        }
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        logger.error("Location request failed: \(error.localizedDescription)")
    }

    // MARK: - CLLocationManagerDelegate

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        permissionStatus = manager.authorizationStatus
        logger.info("Location authorization changed: \(String(describing: manager.authorizationStatus.rawValue))")
        updateLocationLockdownFlag()

        // When Always permission is granted after geofences were registered during .notDetermined,
        // the system may not have delivered any events yet. Request a fresh GPS fix and
        // re-check state for all monitored regions now that we have permission.
        // Note: .authorizedWhenInUse is insufficient for background geofencing and triggers lockdown.
        if !locationLists.isEmpty,
           manager.authorizationStatus == .authorizedAlways {
            logger.info("Permission granted with \(self.locationManager.monitoredRegions.count) regions — requesting location fix and state")
            locationManager.requestLocation()
            for region in locationManager.monitoredRegions {
                locationManager.requestState(for: region)
            }
        }
    }

    func locationManager(_ manager: CLLocationManager, didEnterRegion region: CLRegion) {
        guard let circularRegion = region as? CLCircularRegion else { return }
        logger.info("Entered region: \(circularRegion.identifier)")
        enteredRegionIDs.insert(circularRegion.identifier)
        persistState()
        updateActiveZoneNames()
        recalculateEffectiveEntries()
    }

    func locationManager(_ manager: CLLocationManager, didExitRegion region: CLRegion) {
        guard let circularRegion = region as? CLCircularRegion else { return }
        logger.info("Exited region: \(circularRegion.identifier)")
        enteredRegionIDs.remove(circularRegion.identifier)
        persistState()
        updateActiveZoneNames()
        recalculateEffectiveEntries()
    }

    func locationManager(_ manager: CLLocationManager, didDetermineState state: CLRegionState, for region: CLRegion) {
        guard let circularRegion = region as? CLCircularRegion else { return }
        switch state {
        case .inside:
            enteredRegionIDs.insert(circularRegion.identifier)
        case .outside, .unknown:
            enteredRegionIDs.remove(circularRegion.identifier)
        @unknown default:
            break
        }
        persistState()
        updateActiveZoneNames()
        recalculateEffectiveEntries()
    }

    func locationManager(_ manager: CLLocationManager, monitoringDidFailFor region: CLRegion?, withError error: Error) {
        logger.error("Monitoring failed for region \(region?.identifier ?? "unknown"): \(error.localizedDescription)")
    }

    // MARK: - Test Helpers

    /// Simulates entering all registered geofences. Used by E2E tests to bypass
    /// GPS/pymobiledevice3 dependency for location-based blocking verification.
    func simulateInsideAllGeofences() {
        for list in locationLists {
            for location in list.locations {
                let regionID = "\(list.id.uuidString)|\(location.id.uuidString)"
                enteredRegionIDs.insert(regionID)
            }
        }
        logger.info("TEST: Simulated entry into all \(self.enteredRegionIDs.count) geofences")
        persistState()
        updateActiveZoneNames()
        recalculateEffectiveEntries()
    }

    /// Simulates exiting all registered geofences. Used by E2E tests to verify
    /// that location-based blocking deactivates when leaving a geofenced area.
    func simulateOutsideAllGeofences() {
        let previousCount = enteredRegionIDs.count
        enteredRegionIDs.removeAll()
        logger.info("TEST: Simulated exit from \(previousCount) geofences")
        persistState()
        updateActiveZoneNames()
        recalculateEffectiveEntries()
    }

    // MARK: - Recalculation

    /// Recalculates which domains should be blocked based on currently-entered geofences.
    /// Writes location-triggered entries to a separate key so they don't overwrite the main blocklist.
    private func recalculateEffectiveEntries() {
        var effectiveEntries = Set<String>()
        var hasWhiteListActive = false

        for list in locationLists {
            let listRegionIDs = list.locations.map { "\(list.id.uuidString)|\($0.id.uuidString)" }
            let isInsideAny = listRegionIDs.contains(where: { enteredRegionIDs.contains($0) })

            if isInsideAny {
                effectiveEntries.formUnion(list.entries)
                if list.mode == .whiteList {
                    hasWhiteListActive = true
                }
            }
        }

        // Write to separate location entries key (not the main whitelist)
        // TODO: Location feature not yet ported to IOSRuleStore on rebuild branch

        logger.info("Location entries updated: \(effectiveEntries.count) entries, mode: \(hasWhiteListActive ? "whiteList" : "blockSpecific")")
        notifyExtensionOfLocationChange()
    }

    /// If any active list requires location but permission is insufficient,
    /// write a lockdown flag so the filter extension blocks all non-system traffic.
    /// "Always Allow" is required for background geofencing; "While Using" is not enough.
    private func updateLocationLockdownFlag() {
        let hasLocationLists = !locationLists.isEmpty
        let status = locationManager.authorizationStatus
        let permissionInsufficient = (status == .denied || status == .restricted || status == .authorizedWhenInUse)

        let shouldLockdown = hasLocationLists && permissionInsufficient

        let defaults = UserDefaults(suiteName: appGroupIdentifier)
        defaults?.set(shouldLockdown, forKey: lockdownKey)
        defaults?.synchronize()

        if shouldLockdown {
            logger.warning("Location permission insufficient (status=\(status.rawValue)) with \(self.locationLists.count) location lists — LOCKDOWN active")
        }
        notifyExtensionOfLocationChange()
    }

    /// Posts a Darwin notification so the filter extension immediately re-reads
    /// UserDefaults instead of waiting for its next periodic refresh.
    private func notifyExtensionOfLocationChange() {
        let center = CFNotificationCenterGetDarwinNotifyCenter()
        let notificationName = GetBoredIdentifiers.DarwinNotification.iOSLocationEntriesChanged
        CFNotificationCenterPostNotification(center, CFNotificationName(notificationName as CFString), nil, nil, true)
        logger.info("Posted Darwin notification: \(notificationName)")
    }

    private func updateActiveZoneNames() {
        var names = Set<String>()
        for list in locationLists {
            for location in list.locations {
                let regionID = "\(list.id.uuidString)|\(location.id.uuidString)"
                if enteredRegionIDs.contains(regionID) {
                    names.insert(location.name)
                }
            }
        }
        DispatchQueue.main.async {
            self.activeZoneNames = names
        }
    }
}
