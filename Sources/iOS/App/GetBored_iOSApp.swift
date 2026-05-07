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
    /// Spike-only setup for the XR Safari AppProxy experiment.
    ///
    /// The Apple WebContent profile and the AppLayerVPN profile are separate
    /// from GetBored's own NEFilterDataProvider. If the app-group allowlist is
    /// stale, the iOS filter can still block `cnbc.com`, `github.com`, or their
    /// child CDNs even though the profiles allow/route them. Launching the debug
    /// app writes this broad test allowlist so AppProxy/Safari-extension spikes
    /// measure proxy behavior instead of being contaminated by old filter state.
    private func seedSafariAppProxySpikeAllowlist() {
        let hosts = [
            "api.github.com",
            "collector.github.com",
            "github.com",
            "github.githubassets.com",

            "docker.com",
            "docker.demdex.net",
            "marlin-2.docker.com",
            "www.docker.com",

            "cnbc.com",
            "gdsapi.cnbc.com",
            "geo.cnbc.com",
            "image.cnbcfm.com",
            "quote.cnbc.com",
            "sc.cnbcfm.com",
            "static-redesign.cnbcfm.com",
            "webql-redesign.cnbcfm.com",
            "www.cnbc.com",
            "zephr-templates.cnbc.com",

            "assets.adobedtm.com",
            "assets.zephr.com",
            "code.jquery.com",
            "securepubads.g.doubleclick.net",
            "sp.auth.adobe.com",
            "www.google-analytics.com",
            "www.googletagmanager.com",

            "developer.apple.com",
            "sf-saas.cdn-apple.com",
            "sfss.cdn-apple.com",
            "www.apple.com",

            "gateway.icloud.com",
            "ocsp.rootca1.amazontrust.com",
            "ocsp.r2m01.amazontrust.com"
        ]

        let rules = hosts.map { SiteRule(url: $0, title: "XR Spike: \($0)") }
        GateKeeper.shared.saveSiteRules(rules)
        GateKeeper.shared.setMode(FilterMode.whiteList.rawValue)
        GateKeeper.shared.setExceptions([])

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
