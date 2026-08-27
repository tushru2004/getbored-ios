import React
import React_RCTAppDelegate
import UIKit

/// UIKit @main AppDelegate that owns the window and mounts the React Native root view.
/// Subclasses RCTAppDelegate so RCTNewArchEnabled=true in Info.plist is honoured.
@main
@objc(AppDelegate)
final class AppDelegate: RCTAppDelegate {

    /// Configures the React Native root and subscribes to iOS-delivered crash
    /// and hang reports before handing launch to the React Native superclass.
    ///
    /// Call flow:
    ///
    ///   UIKit launch → configure React Native root properties
    ///       │
    ///       ├── MetricKitReporter.start()  ← registers crash/hang subscriber once
    ///       └── RCTAppDelegate.application(...) → mounts the JS root view
    override func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        self.moduleName = "GetBoredIOS"
        self.initialProps = [:]
        // Crash/hang diagnostics via MetricKit — see MetricKitReporter.
        MetricKitReporter.shared.start()
        return super.application(application, didFinishLaunchingWithOptions: launchOptions)
    }

    override func sourceURL(for bridge: RCTBridge) -> URL? {
        bundleURL()
    }

    /// Selects the JS bundle source for the React Native bridge.
    ///
    /// Call flow:
    ///
    ///   RCTAppDelegate.sourceURL(for:) → bundleURL()
    ///           │
    ///           ├── DEBUG → Metro URL for the `index` bundle root
    ///           └── RELEASE → embedded main.jsbundle
    override func bundleURL() -> URL? {
        #if DEBUG
            RCTBundleURLProvider.sharedSettings().jsLocation = "pro.local"
            return RCTBundleURLProvider.sharedSettings().jsBundleURL(forBundleRoot: "index")
        #else
            return Bundle.main.url(forResource: "main", withExtension: "jsbundle")
        #endif
    }
}
