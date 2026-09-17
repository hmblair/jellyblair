import SwiftUI

/// Layout shared by the regular window's glass panes: the book screen's
/// pane card and the playback bar. The system draws the sidebar with its
/// own inset and corner radius and exposes neither, so the panes here
/// copy the sidebar's values and every pane in the window matches.
enum PaneLayout {
    /// The sidebar's corner radius on macOS 26.
    static let cornerRadius: CGFloat = 10
    /// The sidebar's inset from the window's edges on macOS 26. Each pane
    /// keeps this inset from the edges it touches, so the panes' outer
    /// edges line up with the sidebar's.
    static let windowInset: CGFloat = 8
    /// Clearance between neighboring panes, the same as the inset from
    /// the window's edges, so every clearance in the window reads alike.
    static let gap: CGFloat = windowInset
    /// Padding that puts a pane one gap under the split view, whose
    /// bottom edge already sits one window inset below the sidebar.
    static let belowSplitViewPadding: CGFloat = gap - windowInset
    /// Resting clearance for the last row, past the bottom fade.
    static let bottomRestingInset: CGFloat = 16
    /// Clearance between the card's top edge and the floating search bar.
    static let cardTopInset: CGFloat = 12
}

/// Draws a pane's backdrop. Either way the pane's own background goes,
/// so the cover wash shows through the rows.
private struct PaneBackdropModifier: ViewModifier {
    let backdrop: PaneBackdrop

    @ViewBuilder
    func body(content: Content) -> some View {
        switch backdrop {
        case .card:
            content
                .padding(.top, PaneLayout.cardTopInset)
                .scrollContentBackground(.hidden)
                .glassEffect(.regular, in: RoundedRectangle(cornerRadius: PaneLayout.cornerRadius))
        case .clear:
            content
                .scrollContentBackground(.hidden)
        }
    }
}

/// Floats a pane's search bar over its list, whose rows fade to nothing in
/// the bar's zone.
private struct FloatingSearchBar<Items: View>: ViewModifier {
    @ViewBuilder let items: Items

    @Environment(\.layoutMetrics) private var metrics

    func body(content: Content) -> some View {
        ZStack(alignment: .top) {
            content.fadedUnderFloatingBar(fadesBottom: true)
            HStack(spacing: 8) {
                items
            }
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, metrics.pane.searchBarHorizontalPadding)
        }
    }
}

extension View {
    /// Floats a pane's search bar over its list. The bar's height comes from
    /// the search field; the capsule buttons stretch to match it exactly.
    func floatingSearchBar(@ViewBuilder items: () -> some View) -> some View {
        modifier(FloatingSearchBar(items: items))
    }

    /// Draws the pane backdrop the metrics call for.
    func paneBackdrop(_ backdrop: PaneBackdrop) -> some View {
        modifier(PaneBackdropModifier(backdrop: backdrop))
    }

    /// Steps a search's matches from the keyboard: return steps forward,
    /// and shift-return steps backward.
    func stepsMatchesOnSubmit(_ step: @escaping (Int) -> Void) -> some View {
        onSubmit {
            step(1)
        }
        .onKeyPress(keys: [.return]) { press in
            guard press.modifiers.contains(.shift) else { return .ignored }
            step(-1)
            return .handled
        }
    }

    /// Runs the action when the user scrolls the view themselves. The
    /// animating phase of programmatic centering does not count.
    func onUserScroll(perform action: @escaping () -> Void) -> some View {
        onScrollPhaseChange { _, newPhase in
            switch newPhase {
            case .tracking, .interacting:
                action()
            default:
                break
            }
        }
    }
}

/// Muted find controls at a search field's right edge: a case-sensitivity
/// toggle, the match position, and arrows stepping through the matches.
struct MatchNavigator: View {
    @Binding var isCaseSensitive: Bool
    let count: Int
    let index: Int
    let isSearching: Bool
    let step: (Int) -> Void

    var body: some View {
        HStack(spacing: 4) {
            Button {
                isCaseSensitive.toggle()
            } label: {
                Image(systemName: "textformat")
            }
            .buttonStyle(.plain)
            .foregroundStyle(isCaseSensitive ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.tertiary))
            .help(isCaseSensitive ? Text("Match any case") : Text("Match case exactly"))
            if isSearching {
                ProgressView()
                    .controlSize(.mini)
            } else {
                Text(count == 0 ? "0/0" : "\(index + 1)/\(count)")
                    .monospacedDigit()
            }
            Button {
                step(-1)
            } label: {
                Image(systemName: "chevron.left")
            }
            .buttonStyle(.plain)
            .disabled(count == 0 || isSearching)
            Button {
                step(1)
            } label: {
                Image(systemName: "chevron.right")
            }
            .buttonStyle(.plain)
            .disabled(count == 0 || isSearching)
        }
        .font(.caption)
        .foregroundStyle(.tertiary)
    }
}
