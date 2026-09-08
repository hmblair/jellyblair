import Foundation

/// The sign-in form's fields and the sign-in itself. The platforms draw the
/// fields differently, so each has its own view, but what the fields hold
/// and what happens to them is written once here.
@MainActor
public struct LoginForm {
    public var serverURLString: String
    public var username: String
    public var password = ""

    /// Seeds the fields from the last session, so signing in again asks only
    /// for the password.
    public init(session: AppSession) {
        serverURLString = session.storedServerURLString
        username = session.storedUsername
    }

    /// True when the fields hold enough to sign in and no attempt is
    /// already running. The password is not required: a server can accept
    /// an account that has none.
    public func canSubmit(to session: AppSession) -> Bool {
        !session.isAuthenticating && !serverURLString.isEmpty && !username.isEmpty
    }

    /// Signs in with the fields as they stand. The session publishes the
    /// outcome, which the form's view shows.
    public func submit(to session: AppSession) {
        Task {
            await session.login(serverURLString: serverURLString, username: username, password: password)
        }
    }
}
