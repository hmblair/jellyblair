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
        .resolvingLayoutDensity()
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

    init(client: JellyfinClient) {
        _scope = State(initialValue: SessionScope(client: client))
    }

    /// Runs a playback key action unless a text field is being edited, which
    /// keeps the keys for typing.
    private func playbackKeyResult(_ player: PlayerController, _ action: @escaping () -> Void) -> KeyPress.Result {
        let isEditingText = NSApp.keyWindow?.firstResponder is NSTextView
        guard player.isReady, !isEditingText else { return .ignored }
        action()
        return .handled
    }

    var body: some View {
        MainView(scope: scope)
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
            .focusedSceneValue(\.refreshActions, RefreshActions(
                refreshLibrary: { [library = scope.library] in Task { await library.load() } }
            ))
            .environment(\.openSettings, JellyBlairKit.OpenSettingsAction {
                openSettingsWindow()
            })
    }
}
