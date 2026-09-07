import SwiftUI

/// The settings rows, shared by both platforms. Each shell supplies its own
/// container: the Mac a window, the phone a sheet.
///
/// The server and account describe the live session, so they disappear once
/// the user signs out.
public struct SettingsRows: View {
    private let session: AppSession
    private let onSignedOut: () -> Void

    /// Takes the action to run after a sign-out, which the phone uses to
    /// close its sheet.
    public init(session: AppSession, onSignedOut: @escaping () -> Void = {}) {
        self.session = session
        self.onSignedOut = onSignedOut
    }

    public var body: some View {
        if session.isSignedIn {
            LabeledContent("Server", value: session.storedServerURLString)
            LabeledContent("Account", value: session.storedUsername)
            Button("Sign Out", role: .destructive) {
                session.signOut()
                onSignedOut()
            }
        } else {
            Text("Not signed in")
                .foregroundStyle(.secondary)
        }
        Section("Playback") {
            SkipIntervalSettings()
        }
    }
}
