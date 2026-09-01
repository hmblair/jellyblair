import Foundation
import Observation

/// Owns the sign-in state: loads stored credentials, verifies the token,
/// performs logins, and signs out when the server rejects the session.
@MainActor
@Observable
public final class AppSession {
    public enum State {
        case verifying
        case needsLogin
        case signedIn(JellyfinClient)
    }

    public private(set) var state: State = .verifying
    public private(set) var loginErrorMessage: String?
    public private(set) var isAuthenticating = false

    private let store = SessionStore()

    public init() {}

    public var isSignedIn: Bool {
        if case .signedIn = state { return true }
        return false
    }

    public var storedServerURLString: String { store.serverURLString ?? "" }
    public var storedUsername: String { store.username ?? "" }

    public func start() async {
        guard let stored = store.loadStoredSession() else {
            state = .needsLogin
            return
        }
        let client = JellyfinClient(serverURL: stored.serverURL, accessToken: stored.token, userID: stored.userID)
        switch await client.verifyStoredToken() {
        case .valid, .unreachable:
            activate(client)
        case .invalid:
            store.clearCredentials()
            loginErrorMessage = "Your session expired. Sign in again."
            state = .needsLogin
        }
    }

    public func login(serverURLString: String, username: String, password: String) async {
        guard let url = Self.normalizeServerURL(serverURLString) else {
            loginErrorMessage = "Enter a valid server URL."
            return
        }
        isAuthenticating = true
        defer { isAuthenticating = false }
        let client = JellyfinClient(serverURL: url)
        do {
            try await client.authenticate(username: username, password: password)
            guard let token = client.sessionToken, let userID = client.sessionUserID else {
                loginErrorMessage = "The server did not return a session."
                return
            }
            store.save(serverURL: url, username: username, userID: userID, token: token)
            loginErrorMessage = nil
            activate(client)
        } catch {
            loginErrorMessage = Self.loginErrorText(for: error)
        }
    }

    public func signOut() {
        store.clearCredentials()
        loginErrorMessage = nil
        state = .needsLogin
    }

    private func activate(_ client: JellyfinClient) {
        client.onUnauthorized = { [weak self, weak client] in
            Task { @MainActor in
                guard let self, let client else { return }
                self.handleUnauthorized(from: client)
            }
        }
        state = .signedIn(client)
    }

    /// Signs out on a rejected token, but only when the complaint comes from
    /// the current client. A stale 401 from a replaced client must not knock
    /// out a session that was just re-established.
    private func handleUnauthorized(from client: JellyfinClient) {
        guard case .signedIn(let current) = state, current === client else { return }
        store.clearCredentials()
        loginErrorMessage = "Your session expired. Sign in again."
        state = .needsLogin
    }

    /// Accepts a bare host and defaults its scheme to https.
    private static func normalizeServerURL(_ text: String) -> URL? {
        var trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if !trimmed.contains("://") {
            trimmed = "https://" + trimmed
        }
        guard let url = URL(string: trimmed), url.host != nil else { return nil }
        return url
    }

    private static func loginErrorText(for error: Error) -> String {
        switch error {
        case JellyfinError.unauthorized:
            return "Wrong username or password."
        case JellyfinError.badStatus(let code):
            return "The server returned status \(code)."
        default:
            return "Cannot reach the server."
        }
    }
}
