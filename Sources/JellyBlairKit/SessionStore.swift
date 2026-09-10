import Foundation

struct StoredSession {
    let serverURL: URL
    let username: String
    let token: String
}

/// Persists the server address and the username in UserDefaults, and the
/// access token in the keychain.
struct SessionStore {
    private static let serverURLKey = "serverURL"
    private static let usernameKey = "username"
    private static let tokenKey = "accessToken"

    private let defaults = UserDefaults.standard
    private let storedToken = KeychainItem(account: Self.tokenKey)

    var serverURLString: String? { defaults.string(forKey: Self.serverURLKey) }
    var username: String? { defaults.string(forKey: Self.usernameKey) }

    func loadStoredSession() -> StoredSession? {
        guard
            let urlString = serverURLString,
            let url = ServerURL.parse(urlString),
            let username,
            let token = storedToken.read()
        else { return nil }
        return StoredSession(serverURL: url, username: username, token: token)
    }

    func save(serverURL: URL, username: String, token: String) {
        defaults.set(serverURL.absoluteString, forKey: Self.serverURLKey)
        defaults.set(username, forKey: Self.usernameKey)
        storedToken.write(token)
    }

    /// Removes the token. Keeps the server and username so the login form
    /// can prefill them.
    func clearCredentials() {
        storedToken.delete()
    }
}
