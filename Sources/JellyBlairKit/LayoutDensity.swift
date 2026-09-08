import SwiftUI

/// How much room the app has for its layout. A Mac window and a full-screen
/// iPad are regular. An iPhone and a narrow iPad window are compact.
public enum LayoutDensity {
    case compact
    case regular
}

public extension EnvironmentValues {
    /// The density of the current presentation. Views read this to choose
    /// between the two layouts, instead of asking which platform they run on.
    @Entry var layoutDensity: LayoutDensity = .regular

    /// The measurements of the current density.
    @Entry var layoutMetrics: LayoutMetrics = .regular
}

/// Reads the density from the running platform's own signal and publishes it
/// with its measurements. This is the only writer of either value, so the two
/// cannot disagree.
private struct ResolvedLayoutDensity: ViewModifier {
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    #endif

    /// macOS has no size class, and every Mac window is wide enough for the
    /// regular layout.
    private var density: LayoutDensity {
        #if os(iOS)
        return horizontalSizeClass == .compact ? .compact : .regular
        #else
        return .regular
        #endif
    }

    func body(content: Content) -> some View {
        content
            .environment(\.layoutDensity, density)
            .environment(\.layoutMetrics, density.metrics)
    }
}

public extension View {
    /// Puts the current density and its measurements in the environment. The
    /// shells apply this once at their root, so no view below reads a size
    /// class or a platform of its own.
    func resolvingLayoutDensity() -> some View {
        modifier(ResolvedLayoutDensity())
    }
}
