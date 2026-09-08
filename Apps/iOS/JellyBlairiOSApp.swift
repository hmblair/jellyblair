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
    @State private var path: [LibraryRoute] = []
    @State private var isShowingSettings = false

    init(session: AppSession, client: JellyfinClient) {
        self.session = session
        _scope = State(initialValue: SessionScope(client: client))
    }

    /// The stack has no detail pane to fill, so a chosen book is pushed and
    /// no selection is left behind. Choosing the same book again pushes again.
    private var pushingSelection: Binding<String?> {
        Binding(
            get: { nil },
            set: { [library = scope.library] id in
                guard let book = library.book(withID: id) else { return }
                path.append(.book(book))
            }
        )
    }

    var body: some View {
        // The bar is a stack sibling, not a safe-area inset: an inset lets
        // scrollable screens extend their frames beneath it, which would
        // put the panes' fades and centering at the screen bottom instead
        // of the bar.
        VStack(spacing: 0) {
            NavigationStack(path: $path) {
                LibraryList(selection: pushingSelection, scope: .constant(nil))
                    .navigationDestination(for: LibraryRoute.self) { route in
                        switch route {
                        case .book(let book):
                            // Identity per book: the playback bar replaces
                            // the route in place, and without this the
                            // screen keeps the previous book's list state.
                            BookView(book: book)
                                .id(book.id)
                                .navigationBarTitleDisplayMode(.inline)
                        case .group(let group):
                            LibraryList(selection: pushingSelection, scope: .constant(group))
                        }
                    }
            }
            PlaybackBar { book in
                path = [.book(book)]
            }
            OfflineIndicator()
                .background(.bar)
        }
        .sheet(isPresented: $isShowingSettings) {
            SettingsScreen(session: session)
        }
        .task {
            scope.connection.start()
            await scope.library.load()
        }
        .onChange(of: scope.connection.isServerReachable) { _, reachable in
            guard reachable, scope.library.errorMessage != nil else { return }
            Task { await scope.library.load() }
        }
        .environment(\.openSettings, OpenSettingsAction {
            isShowingSettings = true
        })
        .environment(\.openAuthor, OpenBookGroupAction { [library = scope.library] name in
            guard let group = library.group(ofKind: .author, named: name) else { return }
            path.append(.group(group))
        })
        .environment(\.openNarrator, OpenBookGroupAction { [library = scope.library] name in
            guard let group = library.group(ofKind: .narrator, named: name) else { return }
            path.append(.group(group))
        })
        .environment(\.openGenre, OpenBookGroupAction { [library = scope.library] name in
            guard let group = library.group(ofKind: .genre, named: name) else { return }
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
