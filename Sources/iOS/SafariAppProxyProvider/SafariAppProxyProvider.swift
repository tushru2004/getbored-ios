import Foundation
import NetworkExtension
import os.log

final class SafariAppProxyProvider: NEAppProxyProvider {
    private let logger = Logger(
        subsystem: "com.getbored.ios.safari-app-proxy",
        category: "SafariAppProxyProvider"
    )
    private let defaults = UserDefaults(suiteName: "group.com.getbored.ios")
    private let flowLogKey = "safari_app_proxy_spike_flows"

    override func startProxy(
        options: [String: Any]? = nil,
        completionHandler: @escaping ((any Error)?) -> Void
    ) {
        logger.info("Safari App Proxy spike started")
        appendEvent("START")
        completionHandler(nil)
    }

    override func stopProxy(
        with reason: NEProviderStopReason,
        completionHandler: @escaping () -> Void
    ) {
        logger.info("Safari App Proxy spike stopped reason=\(reason.rawValue, privacy: .public)")
        appendEvent("STOP reason=\(reason.rawValue)")
        completionHandler()
    }

    override func handleNewFlow(_ flow: NEAppProxyFlow) -> Bool {
        let endpoint = describeRemoteEndpoint(for: flow)
        let source = flow.metaData.sourceAppSigningIdentifier
        logger.info("Safari App Proxy flow source=\(source, privacy: .public) endpoint=\(endpoint, privacy: .public)")
        appendEvent("FLOW source=\(source) endpoint=\(endpoint)")

        // Spike behavior: returning false closes the flow. That is intentional
        // for the first proof because it tells us Safari was routed here before
        // the network request completed. A production proxy must retain and
        // forward accepted flows instead.
        return false
    }

    private func describeRemoteEndpoint(for flow: NEAppProxyFlow) -> String {
        if let tcpFlow = flow as? NEAppProxyTCPFlow {
            return String(describing: tcpFlow.remoteEndpoint)
        }
        return String(describing: type(of: flow))
    }

    private func appendEvent(_ event: String) {
        let timestamp = ISO8601DateFormatter().string(from: Date())
        var events = defaults?.stringArray(forKey: flowLogKey) ?? []
        events.append("\(timestamp) \(event)")
        defaults?.set(Array(events.suffix(100)), forKey: flowLogKey)
        defaults?.synchronize()
    }
}
