import JellyBlairKit
import SwiftUI

/// Settings sheet showing the current server and account, with sign-out.
struct SettingsScreen: View {
    let session: AppSession

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                LabeledContent("Server", value: session.storedServerURLString)
                LabeledContent("Account", value: session.storedUsername)
                Button("Sign Out", role: .destructive) {
                    session.signOut()
                    dismiss()
                }
                Section("Playback") {
                    SkipIntervalSettings()
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
