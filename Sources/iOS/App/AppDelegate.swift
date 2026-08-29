import React
import React_RCTAppDelegate
import ReactAppDependencyProvider
import UIKit

/// UIKit entry point that creates the React Native factory, starts native
/// diagnostics, and mounts the GetBored JavaScript application.
@main
@objc(AppDelegate)
final class AppDelegate: UIResponder, UIApplicationDelegate {

    var window: UIWindow?
    private var reactNativeDelegate: ReactNativeDelegate?
    private var reactNativeFactory: RCTReactNativeFactory?

    /// Creates and retains React Native's factory objects for the lifetime of
    /// the application, then mounts the root view into the app window.
    ///
    /// Call flow:
    ///
    ///   UIKit launch → create factory → start MetricKit → mount GetBoredIOS
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        let delegate = ReactNativeDelegate()
        delegate.dependencyProvider = RCTAppDependencyProvider()
        let factory = RCTReactNativeFactory(delegate: delegate)

        reactNativeDelegate = delegate
        reactNativeFactory = factory
        window = UIWindow(frame: UIScreen.main.bounds)

        MetricKitReporter.shared.start()
        factory.startReactNative(
            withModuleName: "GetBoredIOS",
            in: window,
            initialProperties: [:],
            launchOptions: launchOptions
        )
        return true
    }
}

/// Provides React Native's bundle location while retaining factory defaults,
/// including the architecture configured by the installed React Native pods.
private final class ReactNativeDelegate: RCTDefaultReactNativeFactoryDelegate {
    override func sourceURL(for bridge: RCTBridge) -> URL? {
        bundleURL()
    }

    /// Selects where React Native loads the JavaScript application.
    ///
    ///   Debug   → Metro serves the `index` bundle from `pro.local`
    ///   Release → the app loads its embedded `main.jsbundle`
    override func bundleURL() -> URL? {
        #if DEBUG
            RCTBundleURLProvider.sharedSettings().jsLocation = "pro.local"
            return RCTBundleURLProvider.sharedSettings().jsBundleURL(forBundleRoot: "index")
        #else
            return Bundle.main.url(forResource: "main", withExtension: "jsbundle")
        #endif
    }
}
