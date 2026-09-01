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

        /**
         * Call flow:
         *
         *   Safari extension
         *       │
         *       ▼
         *   beginRequest(context:)
         *       │
         *       ├─ extract message from NSExtensionItem
         *       │
         *       ▼
         *   storeProbe(message)
         *       │
         *       ├─ isClearMessage? → clearActiveContext() → return true
         *       │
         *       └─ normal message
         *           ├─ parse {parentDomain, childDomains, url}
         *           ├─ contextStore.saveActiveContext()
         *           └─ return true
         *       │
         *       ▼
         *   completeRequest() with ack={stored, storedKey}
         */
        func beginRequest(with context: NSExtensionContext) {
            let request = context.inputItems.first as? NSExtensionItem
            let message = extensionMessage(from: request)
            let stored = storeProbe(message)

            let response = NSExtensionItem()
            response.userInfo = [
                messageKey: [
                    "ack": stored,
                    "storedKey": SafariParentChildContextStore.activeContextDataKey,
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

        /**
         * Branch point for an inbound Safari extension message: either clear the
         * active context or store a new one. Always returns `true` — the ack sent
         * back to the web extension reports "message received", NOT "context was
         * persisted" (`saveActiveContext` silently no-ops if `IOSDecisionCore`
         * rejects the input).
         *
         * Call flow:
         *
         *   beginRequest → storeProbe(message)
         *           │
         *           ├── isClearMessage(message) → clearActiveContext(message) → return true
         *           │
         *           └── normal message:
         *                   ├── read parentDomain / childDomains / url  (missing → "" / [])
         *                   ├── contextStore.saveActiveContext(...)  ← may no-op if IOSDecisionCore rejects it
         *                   └── return true
         */
        @discardableResult
        private func storeProbe(_ message: Any?) -> Bool {
            if isClearMessage(message) {
                clearActiveContext(message)
                return true
            }

            let now = Date()
            let dictionary = message as? [String: Any] ?? [:]
            contextStore.saveActiveContext(
                parentDomain: dictionary["parentDomain"] as? String ?? "",
                childDomains: dictionary["childDomains"] as? [String] ?? [],
                url: dictionary["url"] as? String ?? "",
                receivedAt: now
            )

            let parent = dictionary["parentDomain"] as? String ?? "unknown"
            let children = dictionary["childDomains"] as? [String] ?? []
            logger.info(
                "Stored Safari extension active context parent=\(parent, privacy: .public) children=\(children.count, privacy: .public)"
            )
            return true
        }

        private func isClearMessage(_ message: Any?) -> Bool {
            let dictionary = message as? [String: Any] ?? [:]
            return dictionary["type"] as? String == "getbored.childRegistrationProbeCleared"
        }

        /**
         * Forwards a tab-unload "cleared" probe to the store, passing the message's
         * `parentDomain` so the store only wipes context it still owns (see
         * `SafariParentChildContextStore.clearActiveContext`). A missing/nil
         * parentDomain lets the store clear unconditionally.
         *
         * Call flow:
         *
         *   storeProbe identifies cleared message → clearActiveContext(message)
         *           │
         *           ├── read optional parentDomain from message
         *           └── contextStore.clearActiveContext(clearingParent:)
         *                   └── clears only context owned by that parent, then records the probe
         */
        private func clearActiveContext(_ message: Any?) {
            let dictionary = message as? [String: Any] ?? [:]
            contextStore.clearActiveContext(clearingParent: dictionary["parentDomain"] as? String)
            logger.info("Cleared Safari extension active page context")
        }
}
