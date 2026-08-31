import SwiftUI

/// Settings pane showing the current server and account, with sign-out.
/// Changing either requires signing in again, so there is no in-place editing.
struct SettingsView: View {
    let session: AppSession

    var body: some View {
        Form {
            LabeledContent("Server", value: session.storedServerURLString)
            LabeledContent("Account", value: session.storedUsername)
            if session.isSignedIn {
                Button("Sign Out") {
                    session.signOut()
                }
            } else {
                Text("Not signed in")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 380)
        .fixedSize()
    }
}
