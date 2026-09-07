import JellyBlairKit
import SwiftUI

/// Settings sheet. Signing out closes it, since the app returns to the
/// login screen.
struct SettingsScreen: View {
    let session: AppSession

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                SettingsRows(session: session) {
                    dismiss()
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                Button("Done") {
                    dismiss()
                }
            }
        }
    }
}
