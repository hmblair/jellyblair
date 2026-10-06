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
            Log.session.notice("No stored session; showing the login form")
            state = .needsLogin
            return
        }
        let client = JellyfinClient(serverURL: stored.serverURL, accessToken: stored.token)
        Log.session.notice("Restored the session for \(stored.serverURL.host() ?? "?", privacy: .public)")
        activate(client)
        await verifyRestoredToken(of: client)
    }

    /// Checks a restored client's token against the server while the library
    /// is already open, and signs out if the server rejects it.
    private func verifyRestoredToken(of client: JellyfinClient) async {
        guard await client.verifyStoredToken() == .invalid else { return }
        handleUnauthorized(from: client)
    }

    public func login(serverURLString: String, username: String, password: String) async {
        guard let url = ServerURL.parse(serverURLString) else {
            loginErrorMessage = String(localized: "Enter a valid server URL.")
            return
        }
        isAuthenticating = true
        defer { isAuthenticating = false }
        let client = JellyfinClient(serverURL: url)
        if let version = await client.fetchServerVersion(), version < .minimumSupported {
            loginErrorMessage = Self.outdatedServerText(for: version)
            return
        }
        do {
            try await client.authenticate(username: username, password: password)
            guard let token = client.sessionToken else {
                loginErrorMessage = String(localized: "The server did not return a session.")
                return
            }
            store.save(serverURL: url, username: username, token: token)
            loginErrorMessage = nil
            activate(client)
        } catch {
            // The message shown is simplified; the log keeps the raw error.
            Log.session.error("Login failed: \(String(describing: error), privacy: .public)")
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
        Log.session.warning("The server rejected the session token; signing out")
        store.clearCredentials()
        loginErrorMessage = String(localized: "Your session expired. Sign in again.")
        state = .needsLogin
    }

    private static func outdatedServerText(for version: ServerVersion) -> String {
        String(localized: "This server runs Jellyfin \(version.description). The app needs \(ServerVersion.minimumSupported.description) or newer.")
    }

    private static func loginErrorText(for error: Error) -> String {
        switch error {
        case JellyfinError.unauthorized:
            return String(localized: "Wrong username or password.")
        case JellyfinError.badStatus(let code):
            return String(localized: "The server returned status \(code).")
        case let error where isBlockedForInsecureTransport(error):
            return String(localized: "The system blocks plain HTTP to this address. Use https instead.")
        default:
            return String(localized: "Cannot reach the server.")
        }
    }

    /// True when App Transport Security refused the request because the
    /// address uses plain HTTP. The system exempts loopback, private
    /// addresses, and local names, so only a public address gets refused.
    private static func isBlockedForInsecureTransport(_ error: Error) -> Bool {
        let error = error as NSError
        return error.domain == NSURLErrorDomain
            && error.code == NSURLErrorAppTransportSecurityRequiresSecureConnection
    }
}
