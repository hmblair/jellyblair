import Foundation

struct StoredSession {
    let serverURL: URL
    let username: String
    let userID: String
    let token: String
}

/// Persists the server address, account identity, and access token in UserDefaults.
/// The server sits behind Tailscale, so the token is not treated as a high-value secret.
struct SessionStore {
    private static let serverURLKey = "serverURL"
    private static let usernameKey = "username"
    private static let userIDKey = "userID"
    private static let tokenKey = "accessToken"

    private let defaults = UserDefaults.standard

    var serverURLString: String? { defaults.string(forKey: Self.serverURLKey) }
    var username: String? { defaults.string(forKey: Self.usernameKey) }

    func loadStoredSession() -> StoredSession? {
        guard
            let urlString = serverURLString,
            let url = URL(string: urlString),
            let username,
            let userID = defaults.string(forKey: Self.userIDKey),
            let token = defaults.string(forKey: Self.tokenKey)
        else { return nil }
        return StoredSession(serverURL: url, username: username, userID: userID, token: token)
    }

    func save(serverURL: URL, username: String, userID: String, token: String) {
        defaults.set(serverURL.absoluteString, forKey: Self.serverURLKey)
        defaults.set(username, forKey: Self.usernameKey)
        defaults.set(userID, forKey: Self.userIDKey)
        defaults.set(token, forKey: Self.tokenKey)
    }

    /// Removes the token and user identity. Keeps the server and username
    /// so the login form can prefill them.
    func clearCredentials() {
        defaults.removeObject(forKey: Self.userIDKey)
        defaults.removeObject(forKey: Self.tokenKey)
    }
}
