//
//  GetBored_iOSApp.swift
//  GetBored iOS
//
//  @main entry point. The actual window and root view are created by AppDelegate
//  (subclass of RCTAppDelegate), which mounts the React Native RCTRootView.
//  This struct satisfies the SwiftUI App protocol requirement while delegating
//  all lifecycle work to the UIKit AppDelegate via @UIApplicationDelegateAdaptor.
//

import SwiftUI

@main
struct GetBored_iOSApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        // Window is owned by RCTAppDelegate — no SwiftUI scene content needed.
        WindowGroup { }
    }
}
