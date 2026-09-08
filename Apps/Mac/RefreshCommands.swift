import SwiftUI

/// Actions the Library menu invokes on the signed-in window.
struct RefreshActions {
    let refreshLibrary: () -> Void
}

private struct RefreshActionsKey: FocusedValueKey {
    typealias Value = RefreshActions
}

extension FocusedValues {
    var refreshActions: RefreshActions? {
        get { self[RefreshActionsKey.self] }
        set { self[RefreshActionsKey.self] = newValue }
    }
}

/// The Library menu. Items are disabled when no signed-in window is focused.
struct RefreshCommands: Commands {
    @FocusedValue(\.refreshActions) private var actions

    var body: some Commands {
        CommandMenu("Library") {
            Button("Refresh Library") {
                actions?.refreshLibrary()
            }
            .keyboardShortcut("r")
            .disabled(actions == nil)
        }
    }
}
