import Foundation
import Security

/// DEAD CODE — deliberately kept, not called anywhere (verified: no reader or
/// writer outside this file's own usage examples).
///
/// This was the CloudKit-era per-device registration ID store. The app has
/// since migrated to the REST API, where the backend mints and owns the device
/// id — stored via `KeychainStore.Item.serverDeviceID` — so nothing reads or
/// writes this type anymore (see `FilterStatusModule`, which notes it "no
/// longer reads" this). It is retained as the reference `KeychainStore` was
/// modeled on, and as a ready second Keychain namespace if a future flow needs
/// one. Do not wire it back in without confirming it is still the shape you want.
///
/// Keychain storage for the per-device CloudKit registration ID.
///
/// iOS Keychain items in the `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`
/// class survive app reinstall and are NOT synced to iCloud Keychain, NOT
/// restored onto a different physical device from an iTunes/iCloud backup.
/// This keeps the ID genuinely unique to THIS physical device while surviving
/// the `UserDefaults` wipe that happens during reinstall.
///
/// Usage:
///
///   // Read (returns nil if never written or on any Keychain error):
///   let id: String? = KeychainDeviceID.read()
///
///   // Persist (delete-then-add pattern avoids errSecDuplicateItem):
///   KeychainDeviceID.write("some-uuid-string")
///
enum KeychainDeviceID {

    // MARK: - Constants

    /// The Keychain service name that namespaces this item.
    private static let service = "com.getbored.ios.deviceID"

    /// The Keychain account key that identifies the device-ID item within the service.
    private static let account = "cloudkitDeviceID"

    // MARK: - Read

    /// Reads the stored device ID from the Keychain.
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
    static func read() -> String? {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
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

    /// Persists the device ID to the Keychain, replacing any previously stored value.
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
    static func write(_ value: String) {
        let deleteQuery: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
        ]
        SecItemDelete(deleteQuery as CFDictionary)

        guard let data = value.data(using: .utf8) else {
            return
        }

        let addAttributes: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecValueData: data,
            kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        SecItemAdd(addAttributes as CFDictionary, nil)
    }
}
