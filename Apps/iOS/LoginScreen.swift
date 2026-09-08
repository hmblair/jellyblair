import JellyBlairKit
import SwiftUI

/// Sign-in form shown when there is no valid stored session.
struct LoginScreen: View {
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
        NavigationStack {
            Form {
                Section("Server") {
                    TextField("https://jellyfin.example.com", text: $serverURLString)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }
                Section("Account") {
                    TextField("Username", text: $username)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    SecureField("Password", text: $password)
                }
                if let message = session.loginErrorMessage {
                    Text(message)
                        .foregroundStyle(.red)
                }
                Section {
                    Button("Connect") {
                        connect()
                    }
                    .disabled(session.isAuthenticating || serverURLString.isEmpty || username.isEmpty)
                }
            }
            .navigationTitle("Connect to Jellyfin")
            .overlay {
                if session.isAuthenticating {
                    ProgressView()
                }
            }
        }
    }

    private func connect() {
        Task {
            await session.login(serverURLString: serverURLString, username: username, password: password)
        }
    }
}
