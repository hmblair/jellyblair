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
        .task {
            await session.start()
        }
    }
}

struct MainScreen: View {
    let session: AppSession
    @State private var library: LibraryViewModel
    @State private var player: PlayerController
    @State private var connection: ConnectionMonitor
    @State private var path: [Book] = []

    init(session: AppSession, client: JellyfinClient) {
        self.session = session
        _library = State(initialValue: LibraryViewModel(client: client))
        _player = State(initialValue: PlayerController(client: client))
        _connection = State(initialValue: ConnectionMonitor(client: client))
    }

    var body: some View {
        NavigationStack(path: $path) {
            LibraryScreen(session: session, library: library, player: player)
                .navigationDestination(for: Book.self) { book in
                    BookView(book: book, player: player, client: library.client)
                        .navigationBarTitleDisplayMode(.inline)
                }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            // The bar shows everywhere except the loaded book's own screen,
            // which already carries the full controls.
            if let loadedBook = player.book, path.last?.id != loadedBook.id {
                MiniPlayerBar(player: player, client: library.client) {
                    path = [loadedBook]
                }
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            if !connection.isServerReachable {
                ConnectionBanner()
            }
        }
        .task {
            connection.start()
            await library.load()
        }
        .onChange(of: connection.isServerReachable) { _, reachable in
            guard reachable, library.errorMessage != nil else { return }
            Task { await library.load() }
        }
    }
}

/// A persistent strip shown while the server is unreachable.
struct ConnectionBanner: View {
    var body: some View {
        Label("Server unreachable — retrying", systemImage: "wifi.exclamationmark")
            .font(.callout)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
            .background(.yellow.opacity(0.25))
    }
}
