import JellyBlairKit
import SwiftUI

/// Sign-in form shown when there is no valid stored session.
struct LoginView: View {
    let session: AppSession

    @State private var form: LoginForm

    init(session: AppSession) {
        self.session = session
        _form = State(initialValue: LoginForm(session: session))
    }

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "headphones")
                .font(.system(size: 40))
                .foregroundStyle(.secondary)
            Text("Connect to Jellyfin")
                .font(.title2.bold())

            Form {
                TextField("Server", text: $form.serverURLString, prompt: Text("https://jellyfin.example.com"))
                TextField("Username", text: $form.username)
                SecureField("Password", text: $form.password)
            }
            // The minimum keeps the fields usable; the window's minimum size
            // follows from the content.
            .frame(minWidth: 280, maxWidth: 360)

            if let message = session.loginErrorMessage {
                Text(message)
                    .font(.callout)
                    .foregroundStyle(.red)
            }

            Button("Connect") {
                form.submit(to: session)
            }
            .keyboardShortcut(.defaultAction)
            .disabled(!form.canSubmit(to: session))

            if session.isAuthenticating {
                ProgressView()
                    .controlSize(.small)
            }
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
