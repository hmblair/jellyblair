import SwiftUI

/// Layout shared by the book screen's chapter and transcript panes.
enum PaneLayout {
    /// Resting clearance for the last row: past the fade, and past the home
    /// indicator on the phone.
    static var bottomRestingInset: CGFloat {
        #if os(iOS)
        return 44
        #else
        return 16
        #endif
    }

    /// Side padding of the transcript text: the phone's content padding, and
    /// the inset list's margin on the Mac.
    static var transcriptHorizontalPadding: CGFloat {
        #if os(iOS)
        return 20
        #else
        return 12
        #endif
    }
}

extension View {
    /// Floats a pane's search bar over its list, whose rows fade to nothing
    /// in the bar's zone. The bar's height comes from the search field; the
    /// capsule buttons stretch to match it exactly.
    func floatingSearchBar(@ViewBuilder items: () -> some View) -> some View {
        ZStack(alignment: .top) {
            fadedUnderFloatingBar(fadesBottom: true)
            HStack(spacing: 8) {
                items()
            }
            .fixedSize(horizontal: false, vertical: true)
            #if os(iOS)
            .padding(.horizontal, 20)
            #endif
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

/// Ghost find controls at a search field's right edge: a case-sensitivity
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
