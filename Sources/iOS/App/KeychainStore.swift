import Foundation
import Security

/// Keychain storage for REST API credentials: the signed-in session token and
/// the server-assigned device ID handed back by the backend.
///
/// iOS Keychain items in the `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`
/// class survive app reinstall and are NOT synced to iCloud Keychain, NOT
/// restored onto a different physical device from an iTunes/iCloud backup.
/// This keeps API credentials genuinely unique to THIS physical device while
/// surviving the `UserDefaults` wipe that happens during reinstall.
///
/// Uses the standard read and delete-then-add Keychain patterns, generalized
/// to a small set of named `Item`s stored under one shared Keychain service.
///
/// Usage:
///
///   // Read (returns nil if never written or on any Keychain error):
///   let token: String? = KeychainStore.read(.sessionToken)
///
///   // Persist (delete-then-add pattern avoids errSecDuplicateItem):
///   KeychainStore.write("abc123", for: .sessionToken)
///
///   // Remove (e.g. on sign-out):
///   KeychainStore.delete(.sessionToken)
///
enum KeychainStore {

    /// The values this store persists. Each case is a distinct Keychain
    /// account within the shared `service` below, so items can be read,
    /// written, and deleted independently of one another.
    enum Item: String {
        case sessionToken
        case serverDeviceID
    }

    // MARK: - Constants

    /// The Keychain service name that namespaces every item this store manages.
    private static let service = "com.getbored.ios.api"

    // MARK: - Read

    /// Reads the stored value for `item` from the Keychain.
    ///
    /// Returns `nil` when no item has been written yet (`errSecItemNotFound`) or
    /// when any other Keychain error occurs. All errors are silently swallowed
    /// because a missing/unreadable entry is treated the same as "not yet set".
    ///
    /// Call flow:
    ///
    ///   look up item
    ///       ├── valid UTF-8 value → return value
    ///       └── missing, unreadable, or invalid → return nil
    static func read(_ item: Item) -> String? {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: item.rawValue,
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne,
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        guard status == errSecSuccess,
            let data = result as? Data,
            let value = String(data: data, encoding: .utf8)
        else {
            return nil
        }

        return value
    }

    // MARK: - Write

    /// Persists `value` for `item` to the Keychain, replacing any previously stored value.
    ///
    /// Uses a delete-then-add pattern so callers never have to handle
    /// `errSecDuplicateItem` from `SecItemUpdate`. Both Keychain operations
    /// are best-effort; their result codes are intentionally ignored.
    ///
    /// Call flow:
    ///
    ///   delete old item → encode value
    ///       ├── failed  → return with old item removed
    ///       └── success → add new item
    static func write(_ value: String, for item: Item) {
        let deleteQuery: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: item.rawValue,
        ]
        SecItemDelete(deleteQuery as CFDictionary)

        guard let data = value.data(using: .utf8) else {
            return
        }

        let addAttributes: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: item.rawValue,
            kSecValueData: data,
            kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        SecItemAdd(addAttributes as CFDictionary, nil)
    }

    // MARK: - Delete

    /// Removes the stored value for `item` from the Keychain, if any.
    ///
    /// Best-effort, matching `write(_:for:)`'s delete step. Every Keychain
    /// result is ignored, so this is safe even when the item was never written.
    static func delete(_ item: Item) {
        let deleteQuery: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: item.rawValue,
        ]
        SecItemDelete(deleteQuery as CFDictionary)
    }
}
