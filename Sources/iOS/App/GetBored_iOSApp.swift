//
//  GetBored_iOSApp.swift
//  GetBored iOS
//
//  The @main entry point for the iOS app.
//  This app shows the filter status, syncs settings from CloudKit,
//  and displays the block log. It does NOT do the actual filtering —
//  that's handled by FlowInspector (DP) and BlockHandler (CP).
//

import SwiftUI

@main
struct GetBored_iOSApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
