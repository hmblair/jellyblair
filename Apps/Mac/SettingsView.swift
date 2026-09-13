import JellyBlairKit
import SwiftUI

/// Settings sheet. Changing the server or the account requires signing in
/// again, so there is no in-place editing. Signing out closes the sheet,
/// since the window returns to the login form.
struct SettingsView: View {
    let session: AppSession

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        MacSheet(title: Text("Settings")) {
            Form {
                SettingsRows(session: session) {
                    dismiss()
                }
            }
            .formStyle(.grouped)
        }
    }
}
