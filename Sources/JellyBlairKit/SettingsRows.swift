import SwiftUI

/// The settings rows, shared by both platforms. Each shell supplies its own
/// container: a sheet on the phone and on the Mac.
///
/// The server and account describe the live session, so they disappear once
/// the user signs out.
public struct SettingsRows: View {
    private let session: AppSession
    private let onSignedOut: () -> Void

    /// The sign-out while its dialog asks about it.
    @State private var pendingAction: DestructiveAction?

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
    /// free-standing button, without a row's own chrome. The explicit red
    /// tint keeps the fill red on both platforms, where the destructive
    /// role alone does not.
    private var signOutButton: some View {
        Button(role: .destructive) {
            pendingAction = signOutAction
        } label: {
            Text("Sign Out")
        }
        .buttonStyle(.borderedProminent)
        .tint(.red)
        .frame(maxWidth: .infinity)
        .confirmsDestructiveAction($pendingAction)
    }

    private var signOutAction: DestructiveAction {
        DestructiveAction(
            question: Text("Sign out of this server?"),
            explanation: Text("The stored login is removed from this device."),
            buttonTitle: Text("Sign Out")
        ) {
            session.signOut()
            onSignedOut()
        }
    }
}
