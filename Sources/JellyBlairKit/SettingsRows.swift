import SwiftUI

/// The settings rows, shared by both platforms. Each shell supplies its own
/// container: a sheet on the phone and on the Mac.
///
/// The server and account describe the live session, so they disappear once
/// the user signs out.
public struct SettingsRows: View {
    private let session: AppSession
    private let onSignedOut: () -> Void

    /// Takes the action to run after a sign-out, which the sheets use to
    /// close.
    public init(session: AppSession, onSignedOut: @escaping () -> Void = {}) {
        self.session = session
        self.onSignedOut = onSignedOut
    }

    public var body: some View {
        if session.isSignedIn {
            Section {
                LabeledContent("Server", value: session.storedServerURLString)
                LabeledContent("Account", value: session.storedUsername)
            } footer: {
                signOutButton
            }
        } else {
            Text("Not signed in")
                .foregroundStyle(.secondary)
        }
        Section("Library") {
            DefaultLibraryFilterSettings()
        }
        Section("Playback") {
            SkipIntervalSettings()
        }
        SettingsInfoSection()
    }

    /// In the section's footer, so it sits close under the rows as a
    /// free-standing button, without a row's own chrome.
    private var signOutButton: some View {
        DestructiveActionButton {
            session.signOut()
            onSignedOut()
        } label: {
            Text("Sign Out")
        }
        .frame(maxWidth: .infinity)
    }
}
