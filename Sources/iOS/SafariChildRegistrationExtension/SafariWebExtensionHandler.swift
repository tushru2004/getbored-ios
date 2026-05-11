import Foundation
import GetBoredCore
import SafariServices
import os.log

final class SafariWebExtensionHandler: NSObject, NSExtensionRequestHandling {
    private let logger = Logger(
        subsystem: GetBoredIdentifiers.Logging.iosSafariChildRegistration,
        category: "SafariWebExtensionHandler"
    )
    private let contextStore = SafariParentChildContextStore()

    func beginRequest(with context: NSExtensionContext) {
        let request = context.inputItems.first as? NSExtensionItem
        let message = extensionMessage(from: request)
        let stored = storeProbe(message)

        let response = NSExtensionItem()
        response.userInfo = [
            messageKey: [
                "ack": stored,
                "storedKey": SafariParentChildContextStore.activeContextDataKey
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
        if isClearMessage(message) {
            clearActiveContext(message)
            return true
        }

        let now = Date()
        let payload = normalizedPayload(from: message, receivedAt: now)
        contextStore.saveActiveContext(
            parentDomain: payload["parentDomain"] as? String ?? "",
            childDomains: payload["childDomains"] as? [String] ?? [],
            url: payload["url"] as? String ?? "",
            receivedAt: now
        )

        let parent = payload["parentDomain"] as? String ?? "unknown"
        let children = payload["childDomains"] as? [String] ?? []
        logger.info("Stored Safari extension active context parent=\(parent, privacy: .public) children=\(children.count, privacy: .public)")
        return true
    }

    private func isClearMessage(_ message: Any?) -> Bool {
        let dictionary = message as? [String: Any] ?? [:]
        return dictionary["type"] as? String == "getbored.childRegistrationProbeCleared"
    }

    private func clearActiveContext(_ message: Any?) {
        let dictionary = message as? [String: Any] ?? [:]
        contextStore.clearActiveContext(clearingParent: dictionary["parentDomain"] as? String)
        logger.info("Cleared Safari extension active page context")
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
