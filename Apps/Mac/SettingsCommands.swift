import JellyBlairKit
import SwiftUI

private struct OpenAppSettingsKey: FocusedValueKey {
    typealias Value = JellyBlairKit.OpenSettingsAction
}

extension FocusedValues {
    var openAppSettings: JellyBlairKit.OpenSettingsAction? {
        get { self[OpenAppSettingsKey.self] }
        set { self[OpenAppSettingsKey.self] = newValue }
    }
}

/// The app menu's Settings item, which presents the settings sheet on the
/// focused window. It replaces the system item, whose settings scene the
/// app does not use.
struct SettingsCommands: Commands {
    @FocusedValue(\.openAppSettings) private var openSettings

    var body: some Commands {
        CommandGroup(replacing: .appSettings) {
            Button("Settings…") {
                openSettings?()
            }
            .keyboardShortcut(",")
            .disabled(openSettings == nil)
        }
    }
}
