import JellyBlairKit
import SwiftUI

/// Settings window. Changing the server or the account requires signing in
/// again, so there is no in-place editing.
struct SettingsView: View {
    let session: AppSession

    var body: some View {
        Form {
            SettingsRows(session: session)
        }
        .formStyle(.grouped)
        .frame(width: 380)
        .fixedSize()
    }
}
