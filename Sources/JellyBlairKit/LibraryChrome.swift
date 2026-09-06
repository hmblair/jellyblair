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

/// The floating bar over a library list: the search field, the grouping
/// toggle when the list is unscoped, and the downloaded-only filter.
public struct LibraryFilterBar: View {
    @Binding var filters: LibraryFilters
    let showsGroupToggle: Bool

    @Environment(LibraryViewModel.self) private var library

    public init(filters: Binding<LibraryFilters>, showsGroupToggle: Bool) {
        _filters = filters
        self.showsGroupToggle = showsGroupToggle
    }

    public var body: some View {
        // The bar's height comes from the search field; the capsule
        // buttons stretch to match it exactly.
        HStack(spacing: 8) {
            CapsuleSearchField("Search", text: $filters.searchQuery)
            if showsGroupToggle {
                groupToggle
            }
            inProgressToggle
            filterToggle
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    /// Cycles the library grouping through author, narrator, and genre.
    private var groupToggle: some View {
        CapsuleIconButton(library.groupKind.iconName, help: "Change the grouping") {
            library.groupKind = library.groupKind.next
        }
    }

    private var inProgressToggle: some View {
        CapsuleIconButton(
            "bookmark.fill",
            isOn: filters.inProgressOnly,
            help: filters.inProgressOnly ? "Show all books" : "Show only books in progress"
        ) {
            filters.inProgressOnly.toggle()
        }
    }

    private var filterToggle: some View {
        CapsuleIconButton(
            "arrow.down",
            weight: .semibold,
            isOn: filters.downloadedOnly,
            help: filters.downloadedOnly ? "Show all books" : "Show only downloaded books"
        ) {
            filters.downloadedOnly.toggle()
        }
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
