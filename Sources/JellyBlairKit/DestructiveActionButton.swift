import SwiftUI

/// How long a confirmation stands before the control reverts, shared by
/// the confirming buttons and rows.
let confirmationWindow: Duration = .seconds(4)

/// A filled red button with white text, for destructive actions. The
/// explicit tint keeps the fill red on both platforms, where the
/// destructive role alone does not.
///
/// A confirming button asks once: the first tap relabels it "Confirm" for
/// a few seconds, and only a second tap within that window runs the
/// action.
public struct DestructiveActionButton<Label: View>: View {
    private let requiresConfirmation: Bool
    private let action: () -> Void
    private let label: Label

    @State private var isConfirming = false
    @State private var confirmationTimeout: Task<Void, Never>?

    public init(
        requiresConfirmation: Bool = true,
        action: @escaping () -> Void,
        @ViewBuilder label: () -> Label
    ) {
        self.requiresConfirmation = requiresConfirmation
        self.action = action
        self.label = label()
    }

    public var body: some View {
        Button {
            handleTap()
        } label: {
            if isConfirming {
                Text("Confirm")
            } else {
                label
            }
        }
        .buttonStyle(.borderedProminent)
        .tint(.red)
    }

    private func handleTap() {
        guard requiresConfirmation else {
            action()
            return
        }
        confirmationTimeout?.cancel()
        guard isConfirming else {
            isConfirming = true
            confirmationTimeout = Task { @MainActor in
                try? await Task.sleep(for: confirmationWindow)
                guard !Task.isCancelled else { return }
                isConfirming = false
            }
            return
        }
        isConfirming = false
        action()
    }
}
