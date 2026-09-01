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
    @State private var library: LibraryViewModel
    @State private var player: PlayerController
    @State private var connection: ConnectionMonitor

    /// Selection is tracked by ID, so it survives library refreshes that
    /// replace the Book values.
    @State private var selectedBookID: String?

    init(client: JellyfinClient) {
        _library = State(initialValue: LibraryViewModel(client: client))
        _player = State(initialValue: PlayerController(client: client))
        _connection = State(initialValue: ConnectionMonitor(client: client))
    }

    private var selectedBook: Book? {
        library.books.first { $0.id == selectedBookID }
    }

    var body: some View {
        NavigationSplitView {
            LibraryView(library: library, selection: $selectedBookID)
                .navigationSplitViewColumnWidth(min: 220, ideal: 260)
        } detail: {
            if let selectedBook {
                PlayerView(player: player, imageURL: library.client.imageURL(for: selectedBook))
                    .id(selectedBook.id)
            } else {
                ContentUnavailableView("Select an audiobook", systemImage: "headphones")
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
        .onChange(of: selectedBookID) { _, newID in
            guard let newBook = library.books.first(where: { $0.id == newID }) else { return }
            player.open(newBook)
        }
        .onChange(of: connection.isServerReachable) { _, reachable in
            guard reachable, library.errorMessage != nil else { return }
            Task { await library.load() }
        }
        .focusedSceneValue(\.refreshActions, RefreshActions(
            refreshLibrary: { Task { await library.load() } },
            refreshChapters: player.book == nil ? nil : { Task { await player.refreshChapters() } }
        ))
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
