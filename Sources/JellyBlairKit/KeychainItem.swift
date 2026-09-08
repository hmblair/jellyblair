import Foundation
import Security

/// Reads and writes one string in the keychain. A failed operation reports
/// nothing, so a caller treats an unreadable item the same as an absent one.
struct KeychainItem {
    let account: String

    private static let service = "JellyBlair"

    private var query: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: account,
        ]
    }

    /// The stored string, or nil when the item is absent or unreadable.
    func read() -> String? {
        var lookup = query
        lookup[kSecReturnData as String] = true
        lookup[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(lookup as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data
        else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Replaces the stored string, adding the item when it is absent.
    func write(_ value: String) {
        guard let data = value.data(using: .utf8) else { return }
        // An update covers an item that is already there, so only its
        // absence leaves anything to add.
        let update = [kSecValueData as String: data]
        guard SecItemUpdate(query as CFDictionary, update as CFDictionary) == errSecItemNotFound else { return }
        var addition = query
        addition[kSecValueData as String] = data
        // The phone reports playback progress while locked, so the token
        // must stay readable after the first unlock.
        addition[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        _ = SecItemAdd(addition as CFDictionary, nil)
    }

    /// Removes the item, if it is there.
    func delete() {
        _ = SecItemDelete(query as CFDictionary)
    }
}
