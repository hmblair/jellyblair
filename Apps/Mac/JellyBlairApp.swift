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
    @Environment(\.openSettings) private var openSettingsWindow: SwiftUI.OpenSettingsAction

    @State private var scope: SessionScope

    /// Selection is tracked by ID, so it survives library refreshes that
    /// replace the Book values.
    @State private var selectedBookID: String?

    /// The sidebar's group scope, owned here so the book screen can set it.
    @State private var sidebarScope: BookGroup?

    /// Which columns the split view shows, read so the library's toolbar
    /// buttons can leave with the sidebar.
    @State private var columnVisibility = NavigationSplitViewVisibility.all

    init(client: JellyfinClient) {
        _scope = State(initialValue: SessionScope(client: client))
    }

    /// True while the split view shows its sidebar.
    private var isSidebarShowing: Bool {
        columnVisibility != .detailOnly
    }

    private var selectedBook: Book? {
        scope.library.books.first { $0.id == selectedBookID }
    }

    /// Runs a playback key action unless a text field is being edited, which
    /// keeps the keys for typing.
    private func playbackKeyResult(_ player: PlayerController, _ action: @escaping () -> Void) -> KeyPress.Result {
        let isEditingText = NSApp.keyWindow?.firstResponder is NSTextView
        guard player.isReady, !isEditingText else { return .ignored }
        action()
        return .handled
    }

    /// The detail pane's width floor. Together with the sidebar's minimum
    /// column width it sets the window's minimum width; the minimum height
    /// comes from the book screen's own content.
    private static let detailMinWidth: CGFloat = 440

    /// The book screen for the selected book, or a placeholder. The book
    /// screen carries its own settings button. The placeholder declares one,
    /// so the title bar keeps the button with no selection.
    private var detail: some View {
        Group {
            if let selectedBook {
                BookView(book: selectedBook)
                    .id(selectedBook.id)
            } else {
                ContentUnavailableView("Select an audiobook", systemImage: "headphones")
                    .toolbar {
                        ToolbarItem(placement: .primaryAction) {
                            SettingsToolbarButton()
                        }
                    }
            }
        }
        .frame(minWidth: Self.detailMinWidth)
    }

    var body: some View {
        VStack(spacing: 0) {
            NavigationSplitView(columnVisibility: $columnVisibility) {
                LibraryView(selection: $selectedBookID, scope: $sidebarScope, isShowing: isSidebarShowing)
                    .navigationSplitViewColumnWidth(min: 220, ideal: 260)
                    .safeAreaInset(edge: .bottom, spacing: 0) {
                        OfflineIndicator()
                    }
            } detail: {
                detail
            }

            PlaybackBar { book in
                selectedBookID = book.id
            }
        }
        // Blank, so the window shows no title text over the book screen.
        .navigationTitle("")
        .onKeyPress(.leftArrow) { [player = scope.player] in
            playbackKeyResult(player) { Task { await player.skip(by: -SkipIntervals.back) } }
        }
        .onKeyPress(.rightArrow) { [player = scope.player] in
            playbackKeyResult(player) { Task { await player.skip(by: SkipIntervals.forward) } }
        }
        .onKeyPress(.space) { [player = scope.player] in
            playbackKeyResult(player) { player.togglePlayback() }
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
        .environment(\.openSettings, JellyBlairKit.OpenSettingsAction {
            openSettingsWindow()
        })
        .environment(\.openAuthor, OpenBookGroupAction { [library = scope.library] name in
            sidebarScope = library.group(ofKind: .author, named: name)
        })
        .environment(\.openNarrator, OpenBookGroupAction { [library = scope.library] name in
            sidebarScope = library.group(ofKind: .narrator, named: name)
        })
        .environment(\.openGenre, OpenBookGroupAction { [library = scope.library] name in
            sidebarScope = library.group(ofKind: .genre, named: name)
        })
        .environment(scope.library)
        .environment(scope.player)
        .environment(scope.connection)
        .environment(scope.catalog)
    }

}

