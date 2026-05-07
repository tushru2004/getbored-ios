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
    private let activeContextKey = "safari_extension_spike_active_page_context"
    private let activeContextDateKey = "safari_extension_spike_active_page_context_at"
    private let activeContextClearedDateKey = "safari_extension_spike_active_page_context_cleared_at"
    private let parentChildRegistryKey = "safari_extension_spike_parent_child_registry"

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

        if isClearMessage(message) {
            clearActiveContext(message, defaults: defaults)
            defaults.synchronize()
            return true
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
        defaults.set(json, forKey: activeContextKey)
        defaults.set(now, forKey: activeContextDateKey)
        updateParentChildRegistry(with: payload, defaults: defaults)
        defaults.synchronize()

        let parent = payload["parentDomain"] as? String ?? "unknown"
        let children = payload["childDomains"] as? [String] ?? []
        logger.info("Stored Safari extension probe parent=\(parent, privacy: .public) children=\(children.count, privacy: .public)")
        return true
    }

    private func isClearMessage(_ message: Any?) -> Bool {
        let dictionary = message as? [String: Any] ?? [:]
        return dictionary["type"] as? String == "getbored.childRegistrationProbeCleared"
    }

    private func clearActiveContext(_ message: Any?, defaults: UserDefaults) {
        let dictionary = message as? [String: Any] ?? [:]
        let clearingParent = normalizedHost(dictionary["parentDomain"] as? String)

        if let activeJSON = defaults.string(forKey: activeContextKey),
           let activeData = activeJSON.data(using: .utf8),
           let activePayload = try? JSONSerialization.jsonObject(with: activeData) as? [String: Any],
           let activeParent = normalizedHost(activePayload["parentDomain"] as? String),
           let clearingParent,
           activeParent != clearingParent {
            return
        }

        defaults.removeObject(forKey: activeContextKey)
        defaults.removeObject(forKey: activeContextDateKey)
        defaults.set(Date(), forKey: activeContextClearedDateKey)
        logger.info("Cleared Safari extension active page context")
    }

    private func updateParentChildRegistry(with payload: [String: Any], defaults: UserDefaults) {
        guard let parent = normalizedHost(payload["parentDomain"] as? String), !parent.isEmpty else {
            return
        }

        let incomingChildren = (payload["childDomains"] as? [String] ?? [])
            .compactMap(normalizedHost)
            .filter { !$0.isEmpty && $0 != parent }

        var registry = defaults.dictionary(forKey: parentChildRegistryKey) as? [String: [String]] ?? [:]
        var existing = Set(registry[parent] ?? [])
        existing.formUnion(incomingChildren)
        registry[parent] = existing.sorted()
        defaults.set(registry, forKey: parentChildRegistryKey)
    }

    private func normalizedHost(_ value: String?) -> String? {
        value?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .trimmingCharacters(in: CharacterSet(charactersIn: "."))
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
