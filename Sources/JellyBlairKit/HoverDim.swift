import SwiftUI

/// Fades a text control while the pointer is over it, so the text reads as
/// clickable without a background.
private struct HoverDim: ViewModifier {
    private static let hoverOpacity: Double = 0.6
    private static let fadeDuration: TimeInterval = 0.1

    @State private var isHovering = false

    func body(content: Content) -> some View {
        content
            .opacity(isHovering ? Self.hoverOpacity : 1)
            .animation(.easeOut(duration: Self.fadeDuration), value: isHovering)
            .onHover { isHovering = $0 }
    }
}

extension View {
    func hoverDim() -> some View {
        modifier(HoverDim())
    }
}
