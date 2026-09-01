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

    init(client: JellyfinClient) {
        _scope = State(initialValue: SessionScope(client: client))
    }

    private var selectedBook: Book? {
        scope.library.books.first { $0.id == selectedBookID }
    }

    var body: some View {
        VStack(spacing: 0) {
            NavigationSplitView {
                LibraryView(selection: $selectedBookID)
                    .navigationSplitViewColumnWidth(min: 220, ideal: 260)
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
        .focusedSceneValue(\.refreshActions, RefreshActions(
            refreshLibrary: { [library = scope.library] in Task { await library.load() } },
            refreshChapters: scope.player.book == nil ? nil : { [player = scope.player] in Task { await player.refreshChapters() } }
        ))
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
