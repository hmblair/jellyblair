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
    @State private var path: [LibraryRoute] = []

    init(session: AppSession, client: JellyfinClient) {
        self.session = session
        _scope = State(initialValue: SessionScope(client: client))
    }

    var body: some View {
        NavigationStack(path: $path) {
            LibraryScreen(session: session)
                .navigationDestination(for: LibraryRoute.self) { route in
                    switch route {
                    case .book(let book):
                        BookView(book: book)
                            .navigationBarTitleDisplayMode(.inline)
                    case .group(let group):
                        BookGroupScreen(group: group)
                    }
                }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            // The bar shows everywhere except the loaded book's own screen,
            // which already carries the full controls.
            if let loadedBook = scope.player.book, path.last != .book(loadedBook) {
                MiniPlayerBar {
                    path = [.book(loadedBook)]
                }
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            OfflineIndicator()
                .background(.bar)
        }
        .task {
            scope.connection.start()
            await scope.library.load()
        }
        .onChange(of: scope.connection.isServerReachable) { _, reachable in
            guard reachable, scope.library.errorMessage != nil else { return }
            Task { await scope.library.load() }
        }
        .environment(\.openBook, OpenBookAction { book in
            path.append(.book(book))
        })
        .environment(\.openAuthor, OpenBookGroupAction { [library = scope.library] name in
            guard let group = library.authorGroups.first(where: { $0.name == name }) else { return }
            path.append(.group(group))
        })
        .environment(\.openNarrator, OpenBookGroupAction { [library = scope.library] name in
            guard let group = library.narratorGroups.first(where: { $0.name == name }) else { return }
            path.append(.group(group))
        })
        .environment(scope.library)
        .environment(scope.player)
        .environment(scope.connection)
        .environment(scope.catalog)
    }
}


/// A destination the library can navigate to.
enum LibraryRoute: Hashable {
    case book(Book)
    case group(BookGroup)
}
