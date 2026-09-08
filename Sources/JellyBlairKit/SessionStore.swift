import Foundation

struct StoredSession {
    let serverURL: URL
    let username: String
    let userID: String
    let token: String
}

/// Persists the server address and the account identity in UserDefaults, and
/// the access token in the keychain.
struct SessionStore {
    private static let serverURLKey = "serverURL"
    private static let usernameKey = "username"
    private static let userIDKey = "userID"
    private static let tokenKey = "accessToken"

    private let defaults = UserDefaults.standard
    private let storedToken = KeychainItem(account: Self.tokenKey)

    var serverURLString: String? { defaults.string(forKey: Self.serverURLKey) }
    var username: String? { defaults.string(forKey: Self.usernameKey) }

    func loadStoredSession() -> StoredSession? {
        moveTokenFromDefaults()
        guard
            let urlString = serverURLString,
            let url = URL(string: urlString),
            let username,
            let userID = defaults.string(forKey: Self.userIDKey),
            let token = storedToken.read()
        else { return nil }
        return StoredSession(serverURL: url, username: username, userID: userID, token: token)
    }

    func save(serverURL: URL, username: String, userID: String, token: String) {
        defaults.set(serverURL.absoluteString, forKey: Self.serverURLKey)
        defaults.set(username, forKey: Self.usernameKey)
        defaults.set(userID, forKey: Self.userIDKey)
        storedToken.write(token)
    }

    /// Removes the token and user identity. Keeps the server and username
    /// so the login form can prefill them.
    func clearCredentials() {
        defaults.removeObject(forKey: Self.userIDKey)
        storedToken.delete()
    }

    /// Moves a token that an earlier version left in UserDefaults into the
    /// keychain. Does nothing once no such token remains.
    private func moveTokenFromDefaults() {
        guard let strayToken = defaults.string(forKey: Self.tokenKey) else { return }
        storedToken.write(strayToken)
        defaults.removeObject(forKey: Self.tokenKey)
    }
}
