import Foundation
import Security

/// Reads and writes the Jellyfin access token in the user's Keychain.
struct KeychainStore {
    private static let service = "com.hmblair.jellyblair"
    private static let account = "jellyfin-access-token"

    private var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: Self.account,
        ]
    }

    func readToken() -> String? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        guard
            SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
            let data = result as? Data
        else { return nil }
        return String(data: data, encoding: .utf8)
    }

    func writeToken(_ token: String) {
        deleteToken()
        var query = baseQuery
        query[kSecValueData as String] = Data(token.utf8)
        SecItemAdd(query as CFDictionary, nil)
    }

    func deleteToken() {
        SecItemDelete(baseQuery as CFDictionary)
    }
}
