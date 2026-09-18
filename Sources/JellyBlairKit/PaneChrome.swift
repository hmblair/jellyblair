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
        #if canImport(AppKit)
        // A List on the Mac is an NSTableView, and SwiftUI reports no
        // scroll phases for it, so the scroll view itself is observed.
        background {
            LiveScrollObserver(action: action)
        }
        #else
        onScrollPhaseChange { _, newPhase in
            switch newPhase {
            case .tracking, .interacting:
                action()
            default:
                break
            }
        }
        #endif
    }
}

#if canImport(AppKit)
/// Observes the list's scroll view for live scrolls, which the user starts
/// with the trackpad or mouse wheel. Programmatic scrolls post none.
private struct LiveScrollObserver: NSViewRepresentable {
    let action: () -> Void

    func makeNSView(context: Context) -> LiveScrollObserverView {
        LiveScrollObserverView()
    }

    func updateNSView(_ view: LiveScrollObserverView, context: Context) {
        view.action = action
    }
}

/// A zero-size view that finds the list's scroll view once attached to a
/// window. SwiftUI hosts a background beside the list, not inside it, so
/// the scroll view is a descendant of a shared ancestor rather than an
/// enclosing view.
private final class LiveScrollObserverView: NSView {
    var action: (() -> Void)?
    private var observer: NSObjectProtocol?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        removeObserver()
        guard window != nil else { return }
        // The list's scroll view is built in the same update, so it is
        // looked up once the update has finished.
        DispatchQueue.main.async { [weak self] in
            self?.attachToScrollView()
        }
    }

    private func attachToScrollView() {
        guard let scrollView = nearestScrollView() else { return }
        observer = NotificationCenter.default.addObserver(
            forName: NSScrollView.willStartLiveScrollNotification,
            object: scrollView,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.action?()
            }
        }
    }

    /// Searches each ancestor's subtree in turn, so the closest scroll view
    /// wins over one that hosts the whole window.
    private func nearestScrollView() -> NSScrollView? {
        if let scrollView = enclosingScrollView { return scrollView }
        var ancestor = superview
        while let node = ancestor {
            if let scrollView = Self.firstScrollView(under: node) { return scrollView }
            ancestor = node.superview
        }
        return nil
    }

    private static func firstScrollView(under root: NSView) -> NSScrollView? {
        var queue = root.subviews
        while !queue.isEmpty {
            let view = queue.removeFirst()
            if let scrollView = view as? NSScrollView { return scrollView }
            queue.append(contentsOf: view.subviews)
        }
        return nil
    }

    private func removeObserver() {
        if let observer {
            NotificationCenter.default.removeObserver(observer)
        }
        observer = nil
    }

    deinit {
        MainActor.assumeIsolated {
            removeObserver()
        }
    }
}
#endif

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
