import UIKit
import React
import React_RCTAppDelegate

/// UIKit @main AppDelegate that owns the window and mounts the React Native root view.
/// Subclasses RCTAppDelegate so RCTNewArchEnabled=true in Info.plist is honoured.
@main
@objc(AppDelegate)
final class AppDelegate: RCTAppDelegate {

    override func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        self.moduleName = "GetBoredIOS"
        self.initialProps = [:]
        return super.application(application, didFinishLaunchingWithOptions: launchOptions)
    }

    override func sourceURL(for bridge: RCTBridge) -> URL? {
        bundleURL()
    }

    override func bundleURL() -> URL? {
        #if DEBUG
        RCTBundleURLProvider.sharedSettings().jsLocation = "192.168.0.137"
        return RCTBundleURLProvider.sharedSettings().jsBundleURL(forBundleRoot: "index")
        #else
        return Bundle.main.url(forResource: "main", withExtension: "jsbundle")
        #endif
    }
}
