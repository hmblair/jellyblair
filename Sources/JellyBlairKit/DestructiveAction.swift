import SwiftUI

/// A destructive action and the question asked before it runs. The
/// question shows in a confirmation dialog, with the action behind a red
/// button beside "Cancel".
public struct DestructiveAction {
    let question: Text
    let explanation: Text
    let buttonTitle: Text
    let run: () -> Void

    public init(question: Text, explanation: Text, buttonTitle: Text, run: @escaping () -> Void) {
        self.question = question
        self.explanation = explanation
        self.buttonTitle = buttonTitle
        self.run = run
    }
}

/// Shows the confirmation dialog for the pending destructive action, and
/// clears it when the dialog closes.
struct DestructiveActionConfirmation: ViewModifier {
    @Binding var pending: DestructiveAction?

    private var isPresented: Binding<Bool> {
        Binding(
            get: { pending != nil },
            set: { if !$0 { pending = nil } }
        )
    }

    func body(content: Content) -> some View {
        content
            .confirmationDialog(
                pending?.question ?? Text(verbatim: ""),
                isPresented: isPresented,
                titleVisibility: .visible,
                presenting: pending
            ) { action in
                Button(role: .destructive, action: action.run) {
                    action.buttonTitle
                }
            } message: { action in
                action.explanation
            }
    }
}

extension View {
    /// Asks about the pending destructive action in a confirmation dialog
    /// anchored to this view.
    public func confirmsDestructiveAction(_ pending: Binding<DestructiveAction?>) -> some View {
        modifier(DestructiveActionConfirmation(pending: pending))
    }
}
