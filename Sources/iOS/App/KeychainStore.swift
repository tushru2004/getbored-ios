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
    ///   SecItemCopyMatching(query, &result)
    ///           │
    ///           ├── errSecSuccess   → cast CFData → Data → UTF-8 String → return String
    ///           │
    ///           └── any other status → return nil
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
    /// `errSecDuplicateItem` from `SecItemUpdate`. The delete is best-effort —
    /// if no item exists yet, `errSecItemNotFound` is silently ignored.
    ///
    /// Call flow:
    ///
    ///   SecItemDelete(deleteQuery)        ← best-effort; ignores errSecItemNotFound
    ///           │
    ///           ▼
    ///   SecItemAdd(addAttributes, nil)    ← writes UTF-8 encoded value
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
    /// Best-effort, matching `write(_:for:)`'s delete step: if no item exists
    /// yet, `errSecItemNotFound` is silently ignored. Safe to call even when
    /// `item` was never written — e.g. signing out a session that failed to
    /// store a token in the first place.
    ///
    /// Call flow:
    ///
    ///   SecItemDelete(deleteQuery)   ← ignores errSecItemNotFound; every other
    ///                                   status is also swallowed, matching the
    ///                                   "errors treated as already gone" contract
    ///                                   of read(_:) above
    static func delete(_ item: Item) {
        let deleteQuery: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: item.rawValue,
        ]
        SecItemDelete(deleteQuery as CFDictionary)
    }
}
