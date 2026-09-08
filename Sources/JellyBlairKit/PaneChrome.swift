import SwiftUI

/// Layout shared by the book screen's chapter and transcript panes.
enum PaneLayout {
    /// Resting clearance for the last row, past the bottom fade.
    static let bottomRestingInset: CGFloat = 16
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
            .help(isCaseSensitive ? "Match any case" : "Match case exactly")
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
