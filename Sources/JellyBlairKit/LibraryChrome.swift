import SwiftUI

/// Height of the zone a floating bar occupies over a list.
public let floatingBarZoneHeight: CGFloat = 34

/// Clearance content keeps under a floating bar: its zone plus a gap.
public let floatingBarClearance: CGFloat = floatingBarZoneHeight + 6

/// Fades a list's rows to nothing under the floating bar's zone, and
/// optionally into the bottom edge.
private struct FloatingBarFade: ViewModifier {
    let fadesBottom: Bool

    func body(content: Content) -> some View {
        content.mask(
            VStack(spacing: 0) {
                Color.clear
                    .frame(height: floatingBarZoneHeight)
                LinearGradient(colors: [.clear, .black], startPoint: .top, endPoint: .bottom)
                    .frame(height: 22)
                Rectangle()
                if fadesBottom {
                    LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom)
                        .frame(height: 22)
                }
            }
        )
    }
}

public extension View {
    /// Fades the view's top under a floating bar, and optionally its bottom
    /// into the screen edge.
    func fadedUnderFloatingBar(fadesBottom: Bool = false) -> some View {
        modifier(FloatingBarFade(fadesBottom: fadesBottom))
    }
}

/// The library's filter toggles for a toolbar: books in progress, and
/// downloaded books. A toggle shows the accent color while it is on.
public struct LibraryFilterToolbarButtons: View {
    @Binding var filters: LibraryFilters

    public init(filters: Binding<LibraryFilters>) {
        _filters = filters
    }

    public var body: some View {
        inProgressToggle
        downloadedToggle
    }

    private var inProgressToggle: some View {
        toggleButton(
            "bookmark.fill",
            isOn: $filters.inProgressOnly,
            help: filters.inProgressOnly ? "Show all books" : "Show only books in progress"
        )
    }

    private var downloadedToggle: some View {
        toggleButton(
            "arrow.down.circle.fill",
            isOn: $filters.downloadedOnly,
            help: filters.downloadedOnly ? "Show all books" : "Show only downloaded books"
        )
    }

    private func toggleButton(_ iconName: String, isOn: Binding<Bool>, help: String) -> some View {
        Button {
            isOn.wrappedValue.toggle()
        } label: {
            Image(systemName: iconName)
        }
        .foregroundStyle(isOn.wrappedValue ? Color.accentColor : Color.secondary)
        .help(help)
    }
}

/// The library list's empty states: loading, a failed first load, or no
/// search matches. A refresh failure keeps the current list; these only
/// cover an empty one.
public struct LibraryEmptyOverlay: View {
    let hasVisibleContent: Bool
    let searchQuery: String

    @Environment(LibraryViewModel.self) private var library

    public init(hasVisibleContent: Bool, searchQuery: String) {
        self.hasVisibleContent = hasVisibleContent
        self.searchQuery = searchQuery
    }

    public var body: some View {
        if library.books.isEmpty {
            if library.isLoading {
                ProgressView()
            } else if let message = library.errorMessage {
                ContentUnavailableView("Cannot load the library", systemImage: "exclamationmark.triangle", description: Text(message))
            }
        } else if !hasVisibleContent {
            ContentUnavailableView.search(text: searchQuery)
        }
    }
}
