import JellyBlairKit
import SwiftUI

/// Sign-in form shown when there is no valid stored session.
struct LoginScreen: View {
    let session: AppSession

    @State private var form: LoginForm

    @Environment(\.layoutDensity) private var density

    /// Width cap of the form. A regular layout has far more width than three
    /// fields need, and a stretched row leaves its label and its field at
    /// opposite edges of the screen.
    private static let formMaxWidth: CGFloat = 420

    /// A compact layout is already narrower than the cap, so it fills its
    /// screen as before.
    private var formWidth: CGFloat {
        density == .regular ? Self.formMaxWidth : .infinity
    }

    init(session: AppSession) {
        self.session = session
        _form = State(initialValue: LoginForm(session: session))
    }

    var body: some View {
        VStack(spacing: 16) {
            Image("JellyBlairGlyph")
                .resizable()
                .scaledToFit()
                .frame(height: 56)
                .foregroundStyle(.secondary)
            Text("Connect to Jellyfin")
                .font(.title2.bold())

            Form {
                Section("Server") {
                    TextField(LoginForm.exampleServerURL, text: $form.serverURLString)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }
                Section("Account") {
                    TextField("Username", text: $form.username)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    SecureField("Password", text: $form.password)
                }
                if let message = session.loginErrorMessage {
                    Text(message)
                        .foregroundStyle(.red)
                }
                Section {
                    Button("Connect") {
                        form.submit(to: session)
                    }
                    .disabled(!form.canSubmit(to: session))
                }
            }
            // The inner cap sizes the form; the outer frame centers it in
            // the width the cap leaves over.
            .frame(maxWidth: formWidth)
            .frame(maxWidth: .infinity)
        }
        .padding(.top, 48)
        // The header sits outside the form, so it paints the form's grouped
        // background to read as one surface.
        .background(Color(.systemGroupedBackground))
        .overlay {
            if session.isAuthenticating {
                ProgressView()
            }
        }
    }
}
