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
        let client = JellyfinClient(serverURL: stored.serverURL, accessToken: stored.token)
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
        guard let url = ServerURL.parse(serverURLString) else {
            loginErrorMessage = "Enter a valid server URL."
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
                loginErrorMessage = "The server did not return a session."
                return
            }
            store.save(serverURL: url, username: username, token: token)
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

    private static func outdatedServerText(for version: ServerVersion) -> String {
        "This server runs Jellyfin \(version). The app needs \(ServerVersion.minimumSupported) or newer."
    }

    private static func loginErrorText(for error: Error) -> String {
        switch error {
        case JellyfinError.unauthorized:
            return "Wrong username or password."
        case JellyfinError.badStatus(let code):
            return "The server returned status \(code)."
        case let error where isBlockedForInsecureTransport(error):
            return "The system blocks plain HTTP to this address. Use https instead."
        default:
            return "Cannot reach the server."
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
