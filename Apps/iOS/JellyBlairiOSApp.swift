import AVFAudio
import JellyBlairKit
import SwiftUI

@main
struct JellyBlairiOSApp: App {
    @State private var session = AppSession()

    init() {
        configureAudioSession()
    }

    var body: some Scene {
        WindowGroup {
            RootScreen(session: session)
        }
    }

    /// Registers the app as a playback client, so audio continues in the
    /// background and pauses other apps' audio.
    private func configureAudioSession() {
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio)
    }
}

/// Switches between the login form and the main screen based on session state.
struct RootScreen: View {
    let session: AppSession

    var body: some View {
        Group {
            switch session.state {
            case .verifying:
                ProgressView()
            case .needsLogin:
                LoginScreen(session: session)
            case .signedIn(let client):
                MainScreen(session: session, client: client)
                    .id(ObjectIdentifier(client))
            }
        }
        .resolvingLayoutDensity()
        .task {
            await session.start()
        }
    }
}

struct MainScreen: View {
    let session: AppSession

    @State private var scope: SessionScope
    @State private var isShowingSettings = false

    init(session: AppSession, client: JellyfinClient) {
        self.session = session
        _scope = State(initialValue: SessionScope(client: client))
    }

    var body: some View {
        MainView(scope: scope)
            .sheet(isPresented: $isShowingSettings) {
                SettingsScreen(session: session)
            }
            .environment(\.openSettings, OpenSettingsAction {
                isShowingSettings = true
            })
    }
}
