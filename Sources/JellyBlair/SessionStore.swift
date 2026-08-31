import Foundation

struct StoredSession {
    let serverURL: URL
    let username: String
    let userID: String
    let token: String
}

/// Persists the server address and account identity in UserDefaults.
/// The access token lives in the Keychain.
struct SessionStore {
    private static let serverURLKey = "serverURL"
    private static let usernameKey = "username"
    private static let userIDKey = "userID"

    private let defaults = UserDefaults.standard
    private let keychain = KeychainStore()

    var serverURLString: String? { defaults.string(forKey: Self.serverURLKey) }
    var username: String? { defaults.string(forKey: Self.usernameKey) }

    func loadStoredSession() -> StoredSession? {
        guard
            let urlString = serverURLString,
            let url = URL(string: urlString),
            let username,
            let userID = defaults.string(forKey: Self.userIDKey),
            let token = keychain.readToken()
        else { return nil }
        return StoredSession(serverURL: url, username: username, userID: userID, token: token)
    }

    func save(serverURL: URL, username: String, userID: String, token: String) {
        defaults.set(serverURL.absoluteString, forKey: Self.serverURLKey)
        defaults.set(username, forKey: Self.usernameKey)
        defaults.set(userID, forKey: Self.userIDKey)
        keychain.writeToken(token)
    }

    /// Removes the token and user identity. Keeps the server and username
    /// so the login form can prefill them.
    func clearCredentials() {
        defaults.removeObject(forKey: Self.userIDKey)
        keychain.deleteToken()
    }
}
