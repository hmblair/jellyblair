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

/// The library's sort menu and filter toggles for a toolbar: the sort
/// order, the books in progress, and the downloaded books. A toggle shows
/// the accent color while it is on; the sort menu keeps one color in every
/// order. The in-progress toggle also puts the list in last-played order.
public struct LibraryFilterToolbarButtons: View {
    @Binding var filters: LibraryFilters

    public init(filters: Binding<LibraryFilters>) {
        _filters = filters
    }

    public var body: some View {
        sortMenu
        inProgressToggle
        downloadedToggle
    }

    private var sortMenu: some View {
        Menu {
            Picker("Sort By", selection: $filters.sortOrder) {
                ForEach(BookSortOrder.allCases) { order in
                    Label(order.label, systemImage: order.iconName)
                        .tag(order)
                }
            }
            .pickerStyle(.inline)
        } label: {
            Image(systemName: "arrow.up.arrow.down")
        }
        .menuIndicator(.hidden)
        .foregroundStyle(Color.secondary)
        .help("Sort the books")
    }

    private var inProgressToggle: some View {
        toggleButton(
            "bookmark.fill",
            isOn: Binding(get: { filters.inProgressOnly }, set: { filters.setInProgressOnly($0) }),
            help: filters.inProgressOnly ? "Show all books" : "Show only books in progress, most recently played first"
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
/// books passing the search and filters. A refresh failure keeps the
/// current list; these only cover an empty one.
public struct LibraryEmptyOverlay: View {
    let hasVisibleContent: Bool

    @Environment(LibraryViewModel.self) private var library

    public init(hasVisibleContent: Bool) {
        self.hasVisibleContent = hasVisibleContent
    }

    public var body: some View {
        if library.books.isEmpty {
            if library.isLoading {
                ProgressView()
            } else if let message = library.errorMessage {
                ContentUnavailableView("Cannot load the library", systemImage: "exclamationmark.triangle", description: Text(message))
            }
        } else if !hasVisibleContent {
            // Emptiness can come from the search or the filter toggles, so
            // the message stays generic.
            ContentUnavailableView("No Results", systemImage: "magnifyingglass")
        }
    }
}
