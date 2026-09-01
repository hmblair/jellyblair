import JellyBlairKit
import SwiftUI

/// Sign-in form shown when there is no valid stored session.
struct LoginView: View {
    let session: AppSession

    @State private var serverURLString: String
    @State private var username: String
    @State private var password = ""

    init(session: AppSession) {
        self.session = session
        _serverURLString = State(initialValue: session.storedServerURLString)
        _username = State(initialValue: session.storedUsername)
    }

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "headphones")
                .font(.system(size: 40))
                .foregroundStyle(.secondary)
            Text("Connect to Jellyfin")
                .font(.title2.bold())

            Form {
                TextField("Server", text: $serverURLString, prompt: Text("https://jellyfin.example.com"))
                TextField("Username", text: $username)
                SecureField("Password", text: $password)
            }
            .frame(maxWidth: 360)

            if let message = session.loginErrorMessage {
                Text(message)
                    .font(.callout)
                    .foregroundStyle(.red)
            }

            Button("Connect") {
                connect()
            }
            .keyboardShortcut(.defaultAction)
            .disabled(session.isAuthenticating || serverURLString.isEmpty || username.isEmpty)

            if session.isAuthenticating {
                ProgressView()
                    .controlSize(.small)
            }
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func connect() {
        Task {
            await session.login(serverURLString: serverURLString, username: username, password: password)
        }
    }
}
