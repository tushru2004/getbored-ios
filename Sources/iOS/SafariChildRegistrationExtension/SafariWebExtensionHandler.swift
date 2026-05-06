import Foundation
import SafariServices
import os.log

final class SafariWebExtensionHandler: NSObject, NSExtensionRequestHandling {
    private let logger = Logger(
        subsystem: "com.getbored.ios.safari-child-registration",
        category: "SafariWebExtensionHandler"
    )
    private let appGroupIdentifier = "group.com.getbored.ios"
    private let lastMessageKey = "safari_extension_spike_last_message"
    private let lastMessageDateKey = "safari_extension_spike_last_message_at"

    func beginRequest(with context: NSExtensionContext) {
        let request = context.inputItems.first as? NSExtensionItem
        let message = extensionMessage(from: request)
        let stored = storeProbe(message)

        let response = NSExtensionItem()
        response.userInfo = [
            messageKey: [
                "ack": stored,
                "storedKey": lastMessageKey
            ]
        ]
        context.completeRequest(returningItems: [response], completionHandler: nil)
    }

    private var messageKey: String {
        if #available(iOS 15.0, macOS 11.0, *) {
            return SFExtensionMessageKey
        }
        return "message"
    }

    private func extensionMessage(from request: NSExtensionItem?) -> Any? {
        request?.userInfo?[messageKey]
    }

    @discardableResult
    private func storeProbe(_ message: Any?) -> Bool {
        guard let defaults = UserDefaults(suiteName: appGroupIdentifier) else {
            logger.error("App Group defaults unavailable: \(self.appGroupIdentifier, privacy: .public)")
            return false
        }

        let now = Date()
        let payload = normalizedPayload(from: message, receivedAt: now)
        guard JSONSerialization.isValidJSONObject(payload),
              let data = try? JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys]),
              let json = String(data: data, encoding: .utf8) else {
            logger.error("Could not serialize Safari extension probe payload")
            return false
        }

        defaults.set(json, forKey: lastMessageKey)
        defaults.set(now, forKey: lastMessageDateKey)
        defaults.synchronize()

        let parent = payload["parentDomain"] as? String ?? "unknown"
        let children = payload["childDomains"] as? [String] ?? []
        logger.info("Stored Safari extension probe parent=\(parent, privacy: .public) children=\(children.count, privacy: .public)")
        return true
    }

    private func normalizedPayload(from message: Any?, receivedAt: Date) -> [String: Any] {
        let dictionary = message as? [String: Any] ?? [:]
        return [
            "type": dictionary["type"] as? String ?? "unknown",
            "url": dictionary["url"] as? String ?? "",
            "parentDomain": dictionary["parentDomain"] as? String ?? "",
            "childDomains": dictionary["childDomains"] as? [String] ?? [],
            "capabilities": dictionary["capabilities"] as? [String: Bool] ?? [:],
            "probeStage": dictionary["probeStage"] as? String ?? "",
            "backgroundError": dictionary["backgroundError"] as? String ?? "",
            "source": "safari-extension-spike",
            "receivedAt": ISO8601DateFormatter().string(from: receivedAt)
        ]
    }
}
