import AppKit
import JellyBlairKit
import SwiftUI

@main
struct JellyBlairApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var session = AppSession()

    var body: some Scene {
        Window("JellyBlair", id: "main") {
            RootView(session: session)
                .frame(minWidth: 760, minHeight: 480)
        }
        .commands {
            CommandGroup(after: .appSettings) {
                Button("Sign Out") {
                    session.signOut()
                }
                .disabled(!session.isSignedIn)
            }
            RefreshCommands()
        }

        Settings {
            SettingsView(session: session)
        }
    }
}

/// Switches between the login form and the main window based on session state.
struct RootView: View {
    let session: AppSession

    var body: some View {
        Group {
            switch session.state {
            case .verifying:
                ProgressView()
            case .needsLogin:
                LoginView(session: session)
            case .signedIn(let client):
                ContentView(client: client)
                    .id(ObjectIdentifier(client))
            }
        }
        .task {
            await session.start()
        }
    }
}

/// Promotes the process to a regular app so a window and dock icon appear when run from the terminal.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        NSWindow.allowsAutomaticWindowTabbing = false
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}

struct ContentView: View {
    @State private var scope: SessionScope

    /// Selection is tracked by ID, so it survives library refreshes that
    /// replace the Book values.
    @State private var selectedBookID: String?

    /// The sidebar's group scope, owned here so the book screen can set it.
    @State private var sidebarScope: BookGroup?

    init(client: JellyfinClient) {
        _scope = State(initialValue: SessionScope(client: client))
    }

    private var selectedBook: Book? {
        scope.library.books.first { $0.id == selectedBookID }
    }

    /// Runs an arrow key skip unless a text field is being edited, whose
    /// caret keeps the arrow keys.
    private func skipKeyResult(_ player: PlayerController, _ skip: @escaping () async -> Void) -> KeyPress.Result {
        let isEditingText = NSApp.keyWindow?.firstResponder is NSTextView
        guard player.isReady, !isEditingText else { return .ignored }
        Task { await skip() }
        return .handled
    }

    var body: some View {
        VStack(spacing: 0) {
            NavigationSplitView {
                LibraryView(selection: $selectedBookID, scope: $sidebarScope)
                    .navigationSplitViewColumnWidth(min: 220, ideal: 260)
                    .safeAreaInset(edge: .bottom, spacing: 0) {
                        OfflineIndicator()
                    }
            } detail: {
                if let selectedBook {
                    BookView(book: selectedBook)
                        .id(selectedBook.id)
                } else {
                    ContentUnavailableView("Select an audiobook", systemImage: "headphones")
                }
            }

            if let loadedBook = scope.player.book, loadedBook.id != selectedBookID {
                MiniPlayerBar {
                    selectedBookID = loadedBook.id
                }
            }
        }
        // Blank, so the window shows no title text over the book screen.
        .navigationTitle("")
        .onKeyPress(.leftArrow) { [player = scope.player] in
            skipKeyResult(player) { await player.skip(by: -30) }
        }
        .onKeyPress(.rightArrow) { [player = scope.player] in
            skipKeyResult(player) { await player.skip(by: 30) }
        }
        .task {
            scope.connection.start()
            await scope.library.load()
        }
        .onChange(of: scope.connection.isServerReachable) { _, reachable in
            guard reachable, scope.library.errorMessage != nil else { return }
            Task { await scope.library.load() }
        }
        .focusedSceneValue(\.refreshActions, RefreshActions(
            refreshLibrary: { [library = scope.library] in Task { await library.load() } }
        ))
        .environment(\.openAuthor, OpenBookGroupAction { [library = scope.library] name in
            sidebarScope = library.authorGroups.first { $0.name == name }
        })
        .environment(\.openNarrator, OpenBookGroupAction { [library = scope.library] name in
            sidebarScope = library.narratorGroups.first { $0.name == name }
        })
        .environment(\.openGenre, OpenBookGroupAction { [library = scope.library] name in
            sidebarScope = library.genreGroups.first { $0.name == name }
        })
        .environment(scope.library)
        .environment(scope.player)
        .environment(scope.connection)
        .environment(scope.catalog)
    }

}

