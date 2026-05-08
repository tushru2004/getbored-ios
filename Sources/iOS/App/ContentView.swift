//
//  ContentView.swift
//  GetBored iOS
//
//  Main screen of the iOS app. This is a viewer/syncer — it does NOT filter.
//  It shows:
//    • Filter status (active/inactive)
//    • iCloud sync status
//    • Block log (activity entries)
//    • Blocked/allowed domains
//    • Allowed apps
//
//  Data flow:
//    macOS app → CloudKit → syncNow() → IOSRuleStore (shared UserDefaults)
//                                            ↓
//                               DP & CP read from IOSRuleStore
//

import SwiftUI
import UIKit
import NetworkExtension
import CloudKit
import os.log

// MARK: - Main View

struct ContentView: View {
    private let logger = Logger(subsystem: "com.getbored.ios", category: "ContentView")
    private let cloudContainerID = "iCloud.com.getbored.sync"

    /// Per-device CloudKit record ID (primary — assigned by macOS app)
    private var perDeviceRecordID: CKRecord.ID? {
        guard let deviceID = UIDevice.current.identifierForVendor?.uuidString else { return nil }
        #if DEBUG
        return CKRecord.ID(recordName: "FilterConfig-\(deviceID)-debug")
        #else
        return CKRecord.ID(recordName: "FilterConfig-\(deviceID)-Production")
        #endif
    }

    /// Shared/fallback CloudKit record ID (backward compatibility)
    private var sharedRecordID: CKRecord.ID {
        #if DEBUG
        CKRecord.ID(recordName: "FilterConfig-debug")
        #else
        CKRecord.ID(recordName: "FilterConfig-Production")
        #endif
    }
    private let lastSyncKey = "lastSyncedAt"

    // MARK: - State

    /// Site rules loaded from IOSRuleStore (the domains being blocked/allowed)
    @State private var siteRules: [SiteRule] = []

    /// Exception patterns (URL paths allowed even if domain is blocked)
    @State private var exceptionItems: [String] = []

    /// Current filter mode: "blockSpecific" or "whiteList"
    @State private var currentMode: String = "blockSpecific"

    /// Bundle IDs of apps that bypass filtering
    @State private var allowedApps: [String] = []

    /// Block log entries from IOSActivityLogger
    @State private var activityEntries: [ActivityLogEntry] = []

    // MARK: - UI State

    /// NEFilterManager status: "Checking...", "Active", "Inactive", or error message
    @State private var filterStatus = "Checking..."

    /// iCloud account status text shown in the status card
    @State private var iCloudStatus = "iCloud: Checking…"

    /// Whether iCloud is available — disables sync button when false
    @State private var iCloudAvailable = false

    /// Sync status text: "Sync: Not yet", "Sync: Ready", "Syncing...", "Sync: Done"
    @State private var syncStatus = "Sync: Not yet"

    /// True while a CloudKit sync is in progress — shows spinner, disables button
    @State private var isSyncing = false

    /// When the last successful sync happened — persisted in shared UserDefaults
    /// so it survives app restart. Read on launch to show "Last synced: ..." text.
    @State private var lastSyncedAt: Date? = UserDefaults(suiteName: "group.com.getbored.ios")?.object(forKey: "lastSyncedAt") as? Date

    /// Triggers the green "Sync Complete" toast animation
    @State private var showSyncSuccess = false

    /// When true, shows the full activity log sheet instead of just top 5
    @State private var showFullActivityLog = false

    /// DEBUG-only readout written by the Safari Web Extension spike native handler.
    @State private var safariExtensionProbeSummary = "No Safari extension probe yet"

    /// Tracks app lifecycle — .active means app is in foreground.
    /// We refresh data and upload activity log when app becomes active.
    @Environment(\.scenePhase) private var scenePhase

    // MARK: - Computed Properties

    /// Detect if running under XCUITest (E2E tests need accessibilityIdentifiers)
    private var isRunningUITests: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    }

    /// Shorthand for filter status check
    private var filterIsActive: Bool { filterStatus == "Active" }

    /// Filter out IP addresses and unresolvable entries from the activity log
    private var resolvedActivityEntries: [ActivityLogEntry] {
        activityEntries.filter { $0.isResolvableHostname }
    }

    /// Count of entries we filtered out (IPs, unresolvable)
    private var unresolvedActivityCount: Int {
        activityEntries.count - resolvedActivityEntries.count
    }

    // MARK: - Body

    /// The main screen layout — a scrollable stack of cards.
    ///
    /// Card order (top to bottom):
    ///   1. statusCard     → Filter on/off, iCloud connected/disconnected
    ///   2. syncCard        → "Sync Now" button, last synced time
    ///   3. activityCard    → Top 5 blocked domains from block log
    ///   4. sitesCard   → Blocked domains (blockSpecific) or allowed domains (whiteList)
    ///   5. allowedAppsCard → Apps bypassing filter (only shown if any exist)
    ///   6. diagnosticsCard → Debug-only card for testing (hidden in Release)
    var body: some View {
        NavigationView {
            ScrollView {
                VStack(spacing: 16) {
                    statusCard          // 1. Filter + iCloud status
                    syncCard            // 2. Sync button + last synced
                    activityCard        // 3. Block log (top 5)
                    sitesCard       // 4. Domain list
                    if !allowedApps.isEmpty {
                        allowedAppsCard // 5. Per-app bypass list
                    }
                    #if DEBUG
                    diagnosticsCard     // 6. Debug tools (only in Debug builds)
                    #endif
                }
                .padding(.horizontal)
                .padding(.top, 8)
                .padding(.bottom, 24)
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("GetBored")
            // Sync button in the top-right corner of the nav bar.
            // Shows a spinner while syncing, disabled if iCloud is unavailable.
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        Task { await syncNow() }
                    } label: {
                        if isSyncing {
                            ProgressView()
                                .tint(.white)
                        } else {
                            Image(systemName: "arrow.triangle.2.circlepath")
                                .font(.system(size: 16, weight: .semibold))
                        }
                    }
                    .disabled(isSyncing || !iCloudAvailable)
                    .accessibilityIdentifier("syncNowButton")
                }
            }
            // Bottom bar for E2E test automation — shows status strings
            // that Appium can read via accessibilityIdentifier
            .safeAreaInset(edge: .bottom) {
                if isRunningUITests {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(iCloudStatus)
                            .accessibilityIdentifier("icloudStatus")
                        Text(syncStatus)
                            .accessibilityIdentifier("syncStatus")
                        if let lastSyncedAt {
                            Text("Last synced: \(lastSyncedAt.formatted(date: .abbreviated, time: .shortened))")
                                .accessibilityIdentifier("lastSyncedAt")
                        }
                    }
                    .font(.caption)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.thinMaterial)
                }
            }
            // Sync success toast overlay
            .overlay {
                if showSyncSuccess {
                    syncSuccessToast
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
            // Initial load — runs once when the view first appears.
            // Loads everything from IOSRuleStore and checks system status.
            .onAppear {
                loadFilterStatus()    // Check NEFilterManager → "Active" or "Inactive"
                loadAppProxyStatus()  // Activate Safari AppProxy tunnel if registered but disconnected
                loadICloudStatus()    // Check CKContainer.accountStatus()
                loadWhitelist()       // Read site rules + exceptions + allowed apps from IOSRuleStore
                loadActivityLog()     // Read block log entries from IOSActivityLogger
                loadSafariExtensionProbe()
                currentMode = IOSRuleStore.shared.getMode()  // "blockSpecific" or "whiteList"
                if lastSyncedAt != nil {
                    syncStatus = "Sync: Ready"
                }
                // Listen for filter config changes — iOS fires this when the user
                // toggles the Content Filter on/off in Settings → General → VPN & Device Management
                NotificationCenter.default.addObserver(
                    forName: .NEFilterConfigurationDidChange,
                    object: nil, queue: .main
                ) { _ in
                    loadFilterStatus()
                }
                // Upload any pending activity log entries to CloudKit so the
                // macOS app can see recent blocks even before the user taps Sync
                Task { await uploadActivityLogToCloudKit() }
            }
            // App lifecycle — refresh data when coming back from background.
            // The filter keeps running while the app is in the background,
            // so there may be new block log entries to display.
            .onChange(of: scenePhase) { phase in
                if phase == .active {
                    loadActivityLog()
                    loadSafariExtensionProbe()
                    Task { await uploadActivityLogToCloudKit() }
                }
            }
        }
    }

    // MARK: - Status Card

    /// Shows two rows:
    ///   1. Content Filter — green shield + "ON" when active, orange shield + "OFF" when inactive
    ///   2. iCloud Sync — blue cloud when connected, red slash when unavailable
    ///
    /// The filter status comes from NEFilterManager (is the content filter enabled?).
    /// The iCloud status comes from CKContainer.accountStatus().
    private var statusCard: some View {
        VStack(spacing: 0) {
            // Row 1: Content Filter status
            HStack(spacing: 12) {
                Image(systemName: filterIsActive ? "checkmark.shield.fill" : "shield.slash")
                    .font(.system(size: 20))
                    .foregroundStyle(.white)
                    .frame(width: 36, height: 36)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(filterIsActive ? Color.green : Color.orange)
                    )

                VStack(alignment: .leading, spacing: 2) {
                    Text("Content Filter")
                        .font(.subheadline.weight(.semibold))
                    Text(filterIsActive ? "Active & Protecting" : filterStatus)
                        .font(.caption)
                        .foregroundStyle(filterIsActive ? .green : .secondary)
                        .accessibilityIdentifier("filterStatus")
                }

                Spacer()

                // ON/OFF pill badge
                Text(filterIsActive ? "ON" : "OFF")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(filterIsActive ? .green : .orange)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(
                        Capsule()
                            .fill(filterIsActive ? Color.green.opacity(0.12) : Color.orange.opacity(0.12))
                    )
            }
            .padding(14)

            Divider().padding(.leading, 62)

            // Row 2: iCloud Sync status
            HStack(spacing: 12) {
                Image(systemName: iCloudAvailable ? "icloud.fill" : "icloud.slash")
                    .font(.system(size: 18))
                    .foregroundStyle(.white)
                    .frame(width: 36, height: 36)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(iCloudAvailable ? Color.blue : Color.red)
                    )

                VStack(alignment: .leading, spacing: 2) {
                    Text("iCloud Sync")
                        .font(.subheadline.weight(.semibold))
                    Text(iCloudStatus.replacingOccurrences(of: "iCloud: ", with: ""))
                        .font(.caption)
                        .foregroundStyle(iCloudAvailable ? Color.secondary : Color.red)
                        .accessibilityIdentifier("icloudStatus_list")
                }

                Spacer()
            }
            .padding(14)
        }
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    // MARK: - Sync Card

    /// Big blue "Sync from iCloud" button + "Last synced X ago" text.
    ///
    /// When tapped, calls syncNow() which:
    ///   1. Fetches the CloudKit record (FilterConfig-debug or FilterConfig-Production)
    ///   2. Decodes site rules, mode, exceptions, allowed apps
    ///   3. Writes everything into IOSRuleStore (shared UserDefaults)
    ///   4. DP and CP pick up the changes on their next flow
    ///
    /// Disabled when iCloud is unavailable or a sync is already in progress.
    private var syncCard: some View {
        VStack(spacing: 12) {
            Button {
                Task { await syncNow() }
            } label: {
                HStack(spacing: 8) {
                    if isSyncing {
                        ProgressView()
                            .tint(.white)
                    } else {
                        Image(systemName: "arrow.triangle.2.circlepath")
                            .font(.system(size: 14, weight: .semibold))
                    }
                    Text(isSyncing ? "Syncing..." : "Sync from iCloud")
                        .font(.subheadline.weight(.semibold))
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(iCloudAvailable ? Color.blue : Color.gray.opacity(0.3))
                )
                .foregroundStyle(.white)
            }
            .disabled(isSyncing || !iCloudAvailable)
            .accessibilityIdentifier("syncNowButton_list")

            // "Last synced X ago" + sync status text
            HStack(spacing: 4) {
                Image(systemName: "clock")
                    .font(.system(size: 10))
                if let lastSyncedAt {
                    Text("Last synced \(lastSyncedAt, style: .relative) ago")
                        .accessibilityIdentifier("lastSyncedAt_list")
                } else {
                    Text("Not yet synced")
                }
                Spacer()
                Text(syncStatus.replacingOccurrences(of: "Sync: ", with: ""))
                    .accessibilityIdentifier("syncStatus_list")
            }
            .font(.caption2)
            .foregroundStyle(.tertiary)
        }
        .padding(14)
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    // MARK: - Whitelist Card

    /// Shows the domain list — what it displays depends on the current mode:
    ///
    /// **blockSpecific mode** (default):
    ///   Header: "Blocked Sites"
    ///   Each row = a domain that IS blocked (e.g., "youtube.com")
    ///   Empty state: "No blocked sites configured"
    ///
    /// **whiteList mode**:
    ///   Header: "Allowed Sites"
    ///   Each row = a domain that is ALLOWED through (everything else is blocked)
    ///   Empty state: "No allowed sites configured"
    ///
    /// Also shows exception patterns (URL paths that bypass blocking even if
    /// the domain is blocked). Example: "reddit.com/r/swift" is allowed even
    /// though "reddit.com" is blocked.
    ///
    /// Layout:
    /// ┌─────────────────────────────────────┐
    /// │  🚫 Blocked Sites              3    │  ← header + count badge
    /// │─────────────────────────────────────│
    /// │  youtube.com                        │  ← siteRuleRow (chunk 7)
    /// │  instagram.com                      │
    /// │  tiktok.com                         │
    /// │─────────────────────────────────────│
    /// │  📝 Exceptions                 1    │  ← only if exceptions exist
    /// │  reddit.com/r/swift                 │
    /// └─────────────────────────────────────┘
    private var sitesCard: some View {
        VStack(spacing: 0) {
            // Header row: icon + title + count badge
            HStack {
                Image(systemName: currentMode == "whiteList" ? "checkmark.circle" : "nosign")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(currentMode == "whiteList" ? .green : .red)

                Text(currentMode == "whiteList" ? "Allowed Sites" : "Blocked Sites")
                    .font(.subheadline.weight(.semibold))

                Spacer()

                // Count badge — shows how many domains are in the list
                Text("\(siteRules.count)")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(
                        Capsule()
                            .fill(Color(.systemGray5))
                    )
            }
            .padding(14)

            Divider().padding(.leading, 14)

            // Domain list — each row is a SiteRule (has url + title)
            // If empty, show a placeholder message.
            if siteRules.isEmpty {
                Text(currentMode == "whiteList"
                     ? "No allowed sites configured"
                     : "No blocked sites configured")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(14)
            } else {
                // LazyVStack for performance — only renders rows on screen.
                // Important for large blocklists (100+ domains).
                LazyVStack(spacing: 0) {
                    ForEach(siteRules) { rule in
                        siteRuleRow(rule)
                        if rule.id != siteRules.last?.id {
                            Divider().padding(.leading, 14)
                        }
                    }
                }
            }

            // Exception patterns section — only shown if any exist.
            // Exceptions are URL paths that bypass blocking. For example,
            // if "reddit.com" is blocked but "reddit.com/r/swift" is an exception,
            // the user can still access that specific subreddit.
            if !exceptionItems.isEmpty {
                Divider()

                HStack {
                    Image(systemName: "text.badge.checkmark")
                        .font(.system(size: 12))
                        .foregroundStyle(.blue)
                    Text("Exceptions")
                        .font(.caption.weight(.semibold))
                    Spacer()
                    Text("\(exceptionItems.count)")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 14)
                .padding(.top, 10)
                .padding(.bottom, 4)

                // List each exception pattern
                ForEach(exceptionItems, id: \.self) { exception in
                    HStack(spacing: 8) {
                        Image(systemName: "arrow.right")
                            .font(.system(size: 9))
                            .foregroundStyle(.tertiary)
                        Text(exception)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 4)
                }
                .padding(.bottom, 8)
            }
        }
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .accessibilityIdentifier("sitesCard")
    }

    // MARK: - Allowed Apps Card

    /// Shows apps that bypass the content filter entirely.
    ///
    /// When an app is in the allowed list, ALL its network traffic passes through
    /// without any filtering — even in whiteList mode. This is useful for
    /// apps the parent trusts (e.g., educational apps, banking apps).
    ///
    /// The list shows bundle IDs (e.g., "com.duolingo.DuolingoMobile") because
    /// we don't have access to app icons or display names on the iOS side.
    /// The macOS companion app resolves these to human-readable names.
    ///
    /// This card is only shown if allowedApps is not empty (see body).
    ///
    /// Layout:
    /// ┌─────────────────────────────────────┐
    /// │  📱 Allowed Apps               2    │
    /// │─────────────────────────────────────│
    /// │  com.duolingo.DuolingoMobile        │
    /// │  com.apple.mobilesafari             │
    /// └─────────────────────────────────────┘
    private var allowedAppsCard: some View {
        VStack(spacing: 0) {
            // Header: icon + title + count badge
            HStack {
                Image(systemName: "app.badge.checkmark")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.blue)

                Text("Allowed Apps")
                    .font(.subheadline.weight(.semibold))

                Spacer()

                // Count badge
                Text("\(allowedApps.count)")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(
                        Capsule()
                            .fill(Color(.systemGray5))
                    )
            }
            .padding(14)

            Divider().padding(.leading, 14)

            // List each allowed app by bundle ID.
            // We strip the team ID prefix if present (e.g., "ABCDE12345.com.app" → "com.app")
            // to keep the display clean. The full bundle ID is still used for filtering.
            LazyVStack(spacing: 0) {
                ForEach(allowedApps, id: \.self) { bundleID in
                    HStack(spacing: 8) {
                        Image(systemName: "app.fill")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)

                        // Strip team ID prefix if present (e.g., "ABCDE12345.com.foo" → "com.foo")
                        let displayName = bundleID.contains(".") && bundleID.split(separator: ".").first?.allSatisfy({ $0.isUppercase || $0.isNumber }) == true
                            ? bundleID.split(separator: ".", maxSplits: 1).last.map(String.init) ?? bundleID
                            : bundleID

                        Text(displayName)
                            .font(.caption)
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                            .truncationMode(.middle)

                        Spacer()
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)

                    if bundleID != allowedApps.last {
                        Divider().padding(.leading, 14)
                    }
                }
            }
        }
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .accessibilityIdentifier("allowedAppsCard")
    }

    // MARK: - Activity Card

    /// Shows the most recent blocked domains from the block log.
    ///
    /// The block log is written by the Control Provider (CP) whenever it blocks
    /// a network flow. Each entry has: domain, app that triggered it, timestamp,
    /// and the reason it was blocked (e.g., "Blocklisted", "Block-everything mode").
    ///
    /// This card shows the top 5 entries. Tapping "See All" opens a full-screen
    /// sheet with the complete log. There's also a refresh button to reload
    /// entries from IOSRuleStore (the CP may have logged new blocks while
    /// the app was in the background).
    ///
    /// IP addresses and unresolvable hostnames are filtered out (see
    /// resolvedActivityEntries computed property) since they're noise
    /// — things like "17.253.144.10" aren't useful to show.
    ///
    /// Layout:
    /// ┌─────────────────────────────────────┐
    /// │  📊 Block Log    🔄         5       │  ← header + refresh + count
    /// │─────────────────────────────────────│
    /// │  youtube.com         2m ago  Safari  │  ← activityRow (chunk 7)
    /// │  instagram.com       5m ago  Safari  │
    /// │  tiktok.com         12m ago  Chrome  │
    /// │  reddit.com         18m ago  Safari  │
    /// │  twitter.com        30m ago  Safari  │
    /// │─────────────────────────────────────│
    /// │  + 12 more entries hidden (IPs)     │  ← unresolved count
    /// │          See All Activity →          │  ← opens full log sheet
    /// └─────────────────────────────────────┘
    private var activityCard: some View {
        VStack(spacing: 0) {
            // Header row: icon + title + refresh button + count badge
            HStack {
                Image(systemName: "chart.bar.fill")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.purple)

                Text("Block Log")
                    .font(.subheadline.weight(.semibold))

                // Refresh button — reloads entries from IOSRuleStore.
                // Useful when the filter has been blocking in the background
                // and the user wants to see the latest entries without
                // waiting for the app lifecycle refresh.
                Button {
                    loadActivityLog()
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                }
                .accessibilityIdentifier("refreshActivityLog")

                Spacer()

                // Count badge — total resolved entries
                Text("\(resolvedActivityEntries.count)")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(
                        Capsule()
                            .fill(Color(.systemGray5))
                    )
            }
            .padding(14)

            Divider().padding(.leading, 14)

            // Activity entries — show top 5 only.
            // Each row is rendered by activityRow() (defined in chunk 7).
            if resolvedActivityEntries.isEmpty {
                Text("No blocked activity yet")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(14)
            } else {
                LazyVStack(spacing: 0) {
                    // prefix(5) — only show the 5 most recent entries.
                    // The full list is available via the "See All" sheet.
                    ForEach(Array(resolvedActivityEntries.prefix(5))) { entry in
                        activityRow(entry)
                        if entry.id != resolvedActivityEntries.prefix(5).last?.id {
                            Divider().padding(.leading, 14)
                        }
                    }
                }
            }

            // Footer: unresolved count + "See All" button
            if !resolvedActivityEntries.isEmpty {
                Divider()

                VStack(spacing: 6) {
                    // Show how many entries were hidden (IPs, unresolvable hostnames)
                    // so the user knows the log isn't incomplete — just filtered.
                    if unresolvedActivityCount > 0 {
                        Text("\(unresolvedActivityCount) entries hidden (IPs/unresolvable)")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }

                    // "See All Activity" button — opens a sheet with the full log.
                    // Uses showFullActivityLog state to trigger the sheet.
                    Button {
                        showFullActivityLog = true
                    } label: {
                        HStack(spacing: 4) {
                            Text("See All Activity")
                                .font(.caption.weight(.medium))
                            Image(systemName: "chevron.right")
                                .font(.system(size: 9, weight: .semibold))
                        }
                        .foregroundStyle(.blue)
                    }
                    .accessibilityIdentifier("seeAllActivity")
                }
                .padding(10)
            }
        }
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .accessibilityIdentifier("activityCard")
        // Full activity log sheet — shows ALL resolved entries, not just top 5.
        // Presented as a sheet that slides up from the bottom.
        .sheet(isPresented: $showFullActivityLog) {
            NavigationView {
                List {
                    ForEach(resolvedActivityEntries) { entry in
                        activityRow(entry)
                    }
                }
                .navigationTitle("Block Log")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .navigationBarTrailing) {
                        Button("Done") {
                            showFullActivityLog = false
                        }
                    }
                }
            }
        }
    }

    // MARK: - Diagnostics Card (Debug Only)

    /// Debug-only card with tools for testing.
    /// Hidden in Release builds via #if DEBUG in body.
    /// Shows: manual cache clear, force sync, dump UserDefaults, etc.
    private var diagnosticsCard: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "wrench.and.screwdriver")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.gray)
                Text("Diagnostics")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Text("DEBUG")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.orange)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(
                        Capsule()
                            .fill(Color.orange.opacity(0.12))
                    )
            }
            .padding(14)

            Divider().padding(.leading, 14)

            VStack(spacing: 8) {
                // Show raw mode value from IOSRuleStore
                HStack {
                    Text("Mode:")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(currentMode)
                        .font(.caption.monospaced())
                    Spacer()
                }

                // Show raw counts
                HStack {
                    Text("Rules: \(siteRules.count)")
                        .font(.caption.monospaced())
                    Spacer()
                    Text("Exceptions: \(exceptionItems.count)")
                        .font(.caption.monospaced())
                    Spacer()
                    Text("Apps: \(allowedApps.count)")
                        .font(.caption.monospaced())
                }
                .foregroundStyle(.secondary)

                // Show total activity count (including unresolved)
                HStack {
                    Text("Activity: \(activityEntries.count) total, \(resolvedActivityEntries.count) resolved")
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                    Spacer()
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text("Safari Extension Spike")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Text(safariExtensionProbeSummary)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .accessibilityIdentifier("safariExtensionProbeSummary")
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(14)
        }
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    // MARK: - CloudKit Sync

    /// Fetches the latest filter configuration from CloudKit and writes it into IOSRuleStore.
    ///
    /// This is the core sync method. The macOS companion app writes filter rules
    /// into a CloudKit record. This method reads that record and decodes it into
    /// local storage so the DP and CP can pick up the changes.
    ///
    /// Flow:
    ///   1. Set UI to syncing state (spinner, disable button)
    ///   2. Fetch the CloudKit record by ID (FilterConfig-debug or FilterConfig-Production)
    ///   3. Decode each field:
    ///      - "urls" → JSON string → [SiteRule] → IOSRuleStore.saveSiteRules()
    ///      - "mode" → String → IOSRuleStore.setMode()
    ///      - "exceptions" → [String] → IOSRuleStore.setExceptions()
    ///      - "allowedApps" → [String] → IOSRuleStore.setAllowedApps()
    ///      - "parent_child_map_v1" → JSON string → IOSRuleStore.saveParentChildMapJSON()
    ///   4. Post Darwin notification so DP/CP invalidate their caches
    ///   5. Reload local state from IOSRuleStore
    ///   6. Update lastSyncedAt timestamp
    ///   7. Show success toast
    ///
    /// Error handling: logs the error, sets syncStatus to the error message.
    /// Does NOT throw — the UI just stays in a non-synced state.
    private func syncNow() async {
        isSyncing = true
        syncStatus = "Syncing..."
        logger.info("Starting CloudKit sync...")

        do {
            // 1. Fetch the CloudKit record (per-device first, then shared fallback)
            let container = CKContainer(identifier: cloudContainerID)
            let database = container.privateCloudDatabase
            let record: CKRecord
            if let perDeviceID = perDeviceRecordID {
                do {
                    record = try await database.record(for: perDeviceID)
                    logger.info("syncNow: using per-device record \(perDeviceID.recordName)")
                } catch {
                    if let ckError = error as? CKError, ckError.code == .unknownItem {
                        logger.info("syncNow: per-device record not found, falling back to shared")
                        record = try await database.record(for: sharedRecordID)
                    } else {
                        throw error
                    }
                }
            } else {
                record = try await database.record(for: sharedRecordID)
            }

            // 2. Decode site rules from JSON string
            //    The macOS app stores rules as a JSON string in the "urls" field.
            //    Format: [{"url": "youtube.com", "title": "YouTube"}, ...]
            if let urlsJSON = record["urls"] as? String,
               let data = urlsJSON.data(using: .utf8) {
                let decoded = try JSONDecoder().decode([SiteRule].self, from: data)
                IOSRuleStore.shared.saveSiteRules(decoded)
                logger.info("Synced \(decoded.count) site rules from CloudKit")
            }

            // 3. Decode filter mode
            if let mode = record["mode"] as? String {
                IOSRuleStore.shared.setMode(mode)
                currentMode = mode
                logger.info("Synced mode: \(mode)")
            }

            // 4. Decode exception patterns
            if let exceptions = record["exceptions"] as? [String] {
                IOSRuleStore.shared.setExceptions(exceptions)
                logger.info("Synced \(exceptions.count) exceptions")
            }

            // 5. Decode allowed apps
            if let apps = record["allowedApps"] as? [String] {
                IOSRuleStore.shared.setAllowedApps(apps)
                logger.info("Synced \(apps.count) allowed apps")
            }

            // 6. Decode the static Safari parent-child map if the macOS app
            //    published one. AppProxy/DataProvider use this to verify that
            //    a child host belongs to the currently active Safari parent.
            if let parentChildMapJSON = record["parent_child_map_v1"] as? String {
                if IOSRuleStore.shared.saveParentChildMapJSON(parentChildMapJSON) {
                    logger.info("Synced Safari parent-child map from CloudKit")
                } else {
                    logger.error("Failed to sync Safari parent-child map: invalid JSON")
                }
            }

            // 7. Post Darwin notification to invalidate DP/CP caches.
            //    Without this, the extensions would keep using stale data
            //    until their 5-second cache TTL expires.
            let notifyName = "com.getbored.filter.configChanged" as CFString
            CFNotificationCenterPostNotification(
                CFNotificationCenterGetDarwinNotifyCenter(),
                CFNotificationName(notifyName),
                nil, nil, true
            )

            // 8. Reload local state from IOSRuleStore so the UI updates immediately
            loadWhitelist()
            loadActivityLog()

            // 9. Update last synced timestamp — persisted to survive app restart
            let now = Date()
            lastSyncedAt = now
            UserDefaults(suiteName: "group.com.getbored.ios")?.set(now, forKey: lastSyncKey)
            syncStatus = "Sync: Done"

            // 10. Show success toast with animation
            withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
                showSyncSuccess = true
            }
            // Auto-hide after 2 seconds
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                withAnimation { showSyncSuccess = false }
            }

            logger.info("CloudKit sync complete")

        } catch {
            logger.error("CloudKit sync failed: \(error.localizedDescription)")
            if let ckError = error as? CKError, ckError.code == .unknownItem {
                syncStatus = "No config found. Create a list in Distraction Manager on your Mac and tap Apply to Devices."
            } else {
                syncStatus = "Sync: \(error.localizedDescription)"
            }
        }

        // Register this device in the DeviceRegistry CloudKit record.
        // Uses a single shared record with a JSON array of all devices,
        // avoiding CKQuery index requirements.
        do {
            let container = CKContainer(identifier: cloudContainerID)
            let database = container.privateCloudDatabase

            #if DEBUG
            let regRecordID = CKRecord.ID(recordName: "DeviceRegistry-debug")
            #else
            let regRecordID = CKRecord.ID(recordName: "DeviceRegistry-Production")
            #endif

            let regRecord: CKRecord
            do {
                regRecord = try await database.record(for: regRecordID)
            } catch {
                regRecord = CKRecord(recordType: "DeviceRegistry", recordID: regRecordID)
            }

            // Decode existing devices list
            var devices: [[String: String]] = []
            if let json = regRecord["devicesJSON"] as? String,
               let data = json.data(using: .utf8),
               let existing = try? JSONSerialization.jsonObject(with: data) as? [[String: String]] {
                devices = existing
            }

            // Build this device's entry
            let deviceID = UIDevice.current.identifierForVendor?.uuidString ?? UUID().uuidString
            let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
            let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
            let iso = ISO8601DateFormatter().string(from: Date())
            let entry: [String: String] = [
                "id": deviceID,
                "deviceName": UIDevice.current.name,
                "deviceModel": UIDevice.current.model,
                "systemVersion": UIDevice.current.systemVersion,
                "appVersion": "\(version) (\(build))",
                "lastSeenAt": iso
            ]

            // Replace existing entry for this device or append
            if let idx = devices.firstIndex(where: { $0["id"] == deviceID }) {
                devices[idx] = entry
            } else {
                devices.append(entry)
            }

            // Save back as JSON
            let jsonData = try JSONSerialization.data(withJSONObject: devices)
            regRecord["devicesJSON"] = String(data: jsonData, encoding: .utf8)! as NSString
            try await database.save(regRecord)
            logger.info("Device registration saved to DeviceRegistry")
        } catch {
            logger.warning("Device registration failed: \(error.localizedDescription)")
        }

        isSyncing = false
    }

    // MARK: - Helper Methods

    /// Checks NEFilterManager to see if the content filter is enabled.
    ///
    /// NEFilterManager.shared().loadFromPreferences() loads the current filter
    /// configuration. If the filter is enabled, filterStatus = "Active".
    /// If not, filterStatus = "Inactive".
    ///
    /// This is called on launch and whenever iOS fires
    /// NEFilterConfigurationDidChange (e.g., user toggles filter in Settings).
    private func loadFilterStatus() {
        NEFilterManager.shared().loadFromPreferences { error in
            DispatchQueue.main.async {
                if let error {
                    filterStatus = error.localizedDescription
                    return
                }
                filterStatus = NEFilterManager.shared().isEnabled ? "Active" : "Inactive"
            }
        }
    }

    /// Brings up the Safari AppProxy tunnel programmatically on launch.
    ///
    /// The AppProxy spike profile registers the NE config but iOS leaves the
    /// session in `.disconnected` state — there is no `OnDemandRules` /
    /// `AlwaysOn` in `Config/ios-safari-app-proxy-spike.mobileconfig` and no
    /// other code path calls `startVPNTunnel()`. Without this, the user has to
    /// manually toggle the VPN in Settings → General → VPN & Device Management
    /// after every fresh install or reboot. Under the dev restrictions profile
    /// (`com.apple.applicationaccess` with `allowVPNCreation=false`) that
    /// manual path is unavailable, so this becomes the only recovery path.
    private func loadAppProxyStatus() {
        NEAppProxyProviderManager.loadAllFromPreferences { managers, error in
            if let error {
                self.logger.warning("AppProxy load failed: \(error.localizedDescription)")
                return
            }
            guard let manager = managers?.first else {
                self.logger.notice("No AppProxy provider registered (profile not installed?)")
                return
            }
            if !manager.isEnabled {
                manager.isEnabled = true
                manager.saveToPreferences { saveError in
                    if let saveError {
                        self.logger.warning("AppProxy save failed: \(saveError.localizedDescription)")
                        return
                    }
                    manager.loadFromPreferences { _ in
                        do {
                            try manager.connection.startVPNTunnel()
                        } catch {
                            self.logger.warning("AppProxy startVPNTunnel failed: \(error.localizedDescription)")
                        }
                    }
                }
            } else if manager.connection.status == .disconnected || manager.connection.status == .invalid {
                do {
                    try manager.connection.startVPNTunnel()
                } catch {
                    self.logger.warning("AppProxy startVPNTunnel failed: \(error.localizedDescription)")
                }
            }
        }
    }

    /// Checks if the user's iCloud account is available.
    ///
    /// Uses CKContainer.accountStatus() to determine if CloudKit is accessible.
    /// Updates both iCloudStatus (display text) and iCloudAvailable (enables/disables sync).
    ///
    /// Possible states:
    ///   .available → "iCloud: Connected", sync enabled
    ///   .noAccount → "iCloud: No Account", sync disabled
    ///   .restricted → "iCloud: Restricted", sync disabled
    ///   .couldNotDetermine → "iCloud: Unknown", sync disabled
    private func loadICloudStatus() {
        let container = CKContainer(identifier: cloudContainerID)
        container.accountStatus { status, error in
            DispatchQueue.main.async {
                switch status {
                case .available:
                    iCloudStatus = "iCloud: Connected"
                    iCloudAvailable = true
                    if syncStatus == "Sync: Not yet" {
                        syncStatus = "Sync: Ready"
                    }
                case .noAccount:
                    iCloudStatus = "iCloud: No Account"
                    iCloudAvailable = false
                case .restricted:
                    iCloudStatus = "iCloud: Restricted"
                    iCloudAvailable = false
                case .couldNotDetermine:
                    iCloudStatus = "iCloud: Unknown"
                    iCloudAvailable = false
                @unknown default:
                    iCloudStatus = "iCloud: Unknown"
                    iCloudAvailable = false
                }
            }
        }
    }

    /// Loads site rules, exceptions, mode, and allowed apps from IOSRuleStore.
    ///
    /// IOSRuleStore wraps shared UserDefaults (group.com.getbored.ios).
    /// All three iOS targets (app, DP, CP) read from the same suite.
    /// The app is the only one that writes (via syncNow).
    private func loadWhitelist() {
        siteRules = IOSRuleStore.shared.loadSiteRules()
        exceptionItems = IOSRuleStore.shared.loadExceptions()
        allowedApps = IOSRuleStore.shared.loadAllowedApps()
        currentMode = IOSRuleStore.shared.getMode()
    }

    /// Loads block log entries from IOSActivityLogger.
    ///
    /// IOSActivityLogger stores entries in shared UserDefaults.
    /// Entries are sorted newest-first so the most recent blocks appear at the top.
    /// The CP writes entries; the app reads them here for display.
    private func loadActivityLog() {
        activityEntries = IOSActivityLogger.shared.loadEntries()
    }

    /// Reads the last Safari Web Extension spike payload from the App Group.
    /// This proves the native handler can write where the app can read.
    private func loadSafariExtensionProbe() {
        #if DEBUG
        let defaults = UserDefaults(suiteName: "group.com.getbored.ios")
        guard let json = defaults?.string(forKey: "safari_extension_spike_last_message"),
              let data = json.data(using: .utf8),
              let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            safariExtensionProbeSummary = "No Safari extension probe yet"
            return
        }

        let parent = payload["parentDomain"] as? String ?? "unknown"
        let children = payload["childDomains"] as? [String] ?? []
        let receivedAt = payload["receivedAt"] as? String ?? "unknown time"
        safariExtensionProbeSummary = "\(parent) -> \(children.count) children @ \(receivedAt)"
        #endif
    }

    /// Uploads the current activity log to CloudKit so the macOS app can see it.
    ///
    /// This runs on app launch and when the app returns to foreground.
    /// It fetches the existing CloudKit record, updates the activityLogJSON field,
    /// and saves it back. This way the parent can see blocked activity on their Mac
    /// even before the child opens the iPhone app.
    ///
    /// Flow:
    ///   1. Load entries from IOSActivityLogger
    ///   2. Encode to JSON
    ///   3. Fetch existing CloudKit record
    ///   4. Update the "activityLogJSON" field
    ///   5. Save back to CloudKit
    private func uploadActivityLogToCloudKit() async {
        let entries = IOSActivityLogger.shared.loadEntries()
        guard !entries.isEmpty else { return }

        do {
            let data = try JSONEncoder().encode(entries)
            guard let jsonString = String(data: data, encoding: .utf8) else { return }

            let container = CKContainer(identifier: cloudContainerID)
            let database = container.privateCloudDatabase

            // Always write activity log to the shared record (not per-device)
            let record = try await database.record(for: sharedRecordID)
            record["activityLogJSON"] = jsonString as CKRecordValue
            try await database.save(record)

            logger.info("Uploaded \(entries.count) activity entries to CloudKit")
        } catch {
            // Non-fatal — activity log upload is best-effort.
            // The macOS app can still pull the log on next manual sync.
            logger.error("Activity log upload failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Sync Success Toast

    /// Green "Sync Complete" banner that slides in from the top after a successful sync.
    ///
    /// Shown via showSyncSuccess state variable. syncNow() triggers it with a
    /// spring animation, then auto-hides after 2 seconds.
    ///
    /// Layout:
    /// ┌─────────────────────────────────────┐
    /// │  ✓  Sync Complete                   │  ← green banner at top
    /// └─────────────────────────────────────┘
    private var syncSuccessToast: some View {
        HStack(spacing: 8) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 16))
            Text("Sync Complete")
                .font(.subheadline.weight(.semibold))
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(
            Capsule()
                .fill(Color.green)
                .shadow(color: .green.opacity(0.3), radius: 8, y: 4)
        )
        .padding(.top, 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    // MARK: - Row Views

    /// A single row in the sitesCard — shows one blocked/allowed domain.
    ///
    /// Displays the domain URL and optionally the title if it differs from the URL.
    /// The icon changes based on the current mode:
    ///   blockSpecific → red nosign (this domain IS blocked)
    ///   whiteList → green checkmark (this domain is ALLOWED through)
    ///
    /// Layout:
    /// ┌─────────────────────────────────────┐
    /// │  🚫  youtube.com                    │  ← blockSpecific mode
    /// │       YouTube                       │  ← title (if different from URL)
    /// └─────────────────────────────────────┘
    private func siteRuleRow(_ rule: SiteRule) -> some View {
        HStack(spacing: 10) {
            // Icon: red nosign for blocked, green check for allowed
            Image(systemName: currentMode == "whiteList" ? "checkmark.circle.fill" : "nosign")
                .font(.system(size: 12))
                .foregroundStyle(currentMode == "whiteList" ? .green : .red)

            VStack(alignment: .leading, spacing: 2) {
                // Domain URL (always shown)
                Text(rule.url)
                    .font(.subheadline)
                    .lineLimit(1)

                // Title (only shown if it's different from the URL — avoids redundancy)
                if !rule.title.isEmpty && rule.title.lowercased() != rule.url.lowercased() {
                    Text(rule.title)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    /// A single row in the activityCard — shows one blocked domain from the log.
    ///
    /// Shows the domain name, how long ago it was blocked (relative time),
    /// and which app triggered the block.
    ///
    /// Layout:
    /// ┌─────────────────────────────────────────────┐
    /// │  🔴  youtube.com         2m ago     Safari   │
    /// └─────────────────────────────────────────────┘
    private func activityRow(_ entry: ActivityLogEntry) -> some View {
        HStack(spacing: 10) {
            // Red dot — indicates this was a blocked request
            Circle()
                .fill(Color.red)
                .frame(width: 6, height: 6)

            // Domain name — the main text
            Text(entry.displayDomain)
                .font(.subheadline)
                .lineLimit(1)

            Spacer()

            // Relative timestamp — "2m ago", "1h ago", etc.
            // Uses SwiftUI's built-in relative date formatter.
            Text(entry.timestamp, style: .relative)
                .font(.caption2)
                .foregroundStyle(.tertiary)

            // Source app — which app triggered the block.
            // Shows the last component of the bundle ID for brevity:
            // "com.apple.mobilesafari" → "mobilesafari"
            if let sourceApp = entry.sourceApp {
                let appName = sourceApp.split(separator: ".").last.map(String.init) ?? sourceApp
                Text(appName)
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(
                        Capsule()
                            .fill(Color(.systemGray5))
                    )
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }
}
