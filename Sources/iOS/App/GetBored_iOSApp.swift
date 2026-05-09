//
//  GetBored_iOSApp.swift
//  GetBored iOS
//
//  The @main entry point for the iOS app.
//  This app shows the filter status, syncs settings from CloudKit,
//  and displays the block log. It does NOT do the actual filtering —
//  that's handled by iOSFilterDataProvider (DP) and iOSFilterControlProvider (CP).
//

import SwiftUI

@main
struct GetBored_iOSApp: App {
    init() {
        #if DEBUG
        seedSafariAppProxySpikeAllowlist()
        #endif
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }

    #if DEBUG
    /// Debug-only setup for the XR Safari AppProxy parent-child experiment.
    ///
    /// The Apple WebContent profile and the AppLayerVPN profile are separate
    /// from GetBored's own NEFilterDataProvider. If the app-group allowlist is
    /// stale, the iOS filter can still block top-level allowed pages even though
    /// the profiles allow/route them. Keep this seed to top-level parent domains
    /// only; child domains must be allowed by the scoped Safari parent-child
    /// policy, not by a flat global allowlist entry.
    private func seedSafariAppProxySpikeAllowlist() {
        let hosts = [
            "aws.amazon.com",
            "benzinga.com",
            "cnbc.com",
            "developer.apple.com",
            "developer.mozilla.org",
            "docker.com",
            "github.com",
            "go.dev",
            "golang.org",
            "kubernetes.io",
            "news.ycombinator.com",
            "nodejs.org",
            "npmjs.com",
            "pypi.org",
            "python.org",
            "react.dev",
            "reactjs.org",
            "rust-lang.org",
            "seekingalpha.com",
            "stackoverflow.com",
            "swift.org"
        ]

        let rules = hosts.map { SiteRule(url: $0, title: "XR Spike: \($0)") }
        IOSRuleStore.shared.saveSiteRules(rules)
        IOSRuleStore.shared.setMode(FilterMode.whiteList.rawValue)
        IOSRuleStore.shared.setExceptions([])

        CFNotificationCenterPostNotification(
            CFNotificationCenterGetDarwinNotifyCenter(),
            CFNotificationName("com.getbored.filter.configChanged" as CFString),
            nil,
            nil,
            true
        )
    }
    #endif
}
