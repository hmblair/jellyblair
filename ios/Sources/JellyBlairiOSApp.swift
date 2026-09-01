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
    @State private var scope: SessionScope
    @State private var path: [Book] = []

    init(session: AppSession, client: JellyfinClient) {
        self.session = session
        _scope = State(initialValue: SessionScope(client: client))
    }

    var body: some View {
        NavigationStack(path: $path) {
            LibraryScreen(session: session)
                .navigationDestination(for: Book.self) { book in
                    BookView(book: book)
                        .navigationBarTitleDisplayMode(.inline)
                }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            // The bar shows everywhere except the loaded book's own screen,
            // which already carries the full controls.
            if let loadedBook = scope.player.book, path.last?.id != loadedBook.id {
                MiniPlayerBar {
                    path = [loadedBook]
                }
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            if !scope.connection.isServerReachable {
                ConnectionBanner()
            }
        }
        .task {
            scope.connection.start()
            await scope.library.load()
        }
        .onChange(of: scope.connection.isServerReachable) { _, reachable in
            guard reachable, scope.library.errorMessage != nil else { return }
            Task { await scope.library.load() }
        }
        .environment(scope.library)
        .environment(scope.player)
        .environment(scope.connection)
        .environment(scope.catalog)
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
