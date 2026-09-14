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

/// Ties a library list's identity to the sort order and direction, so each
/// sorting shows a fresh list, which starts at the top.
private struct ScrollToTopOnSortChange: ViewModifier {
    struct Sorting: Hashable {
        let order: BookSortOrder
        let direction: SortDirection
    }

    let sorting: Sorting

    func body(content: Content) -> some View {
        content.id(sorting)
    }
}

public extension View {
    /// Keeps a library list at its top through a change of sort order or
    /// direction.
    func scrolledToTopOnSortChange(filters: LibraryFilters) -> some View {
        modifier(ScrollToTopOnSortChange(sorting: .init(
            order: filters.sortOrder,
            direction: filters.sortDirection
        )))
    }
}

/// The symbol on the sort menu's toolbar button.
private let sortMenuIcon = Icon("arrow.up.arrow.down.circle.fill", hasGlyphLayer: true)

/// The symbol on the filter menu's toolbar button.
private let filterMenuIcon = Icon("line.3.horizontal.decrease.circle.fill", hasGlyphLayer: true)

/// The library's sort menu and filter menu for a toolbar, marking the
/// active choices by coloring their icons accent. The reading filter also
/// puts the list in last-played order.
public struct LibraryFilterToolbarButtons: View {
    @Binding var filters: LibraryFilters

    @Environment(\.self) private var environment

    public init(filters: Binding<LibraryFilters>) {
        _filters = filters
    }

    public var body: some View {
        sortMenu
        filterMenu
    }

    private var sortMenu: some View {
        toolbarMenu(sortMenuIcon, help: "Sort the books") {
            ForEach(BookSortOrder.allCases) { order in
                menuChoice(order.label, icon: order.icon, isOn: filters.sortOrder == order) {
                    filters.setSortOrder(order)
                }
            }
            Divider()
            // Shows the current direction; choosing it flips the list.
            menuChoice(filters.sortDirection.label, icon: filters.sortDirection.icon, isOn: false) {
                filters.toggleSortDirection()
            }
        }
    }

    private var filterMenu: some View {
        toolbarMenu(filterMenuIcon, help: "Filter the books", isHighlighted: filters.hasActiveFilter) {
            menuChoice("Unread", icon: unreadIcon, isOn: filters.playedFilter == .unread) {
                filters.togglePlayedFilter(.unread)
            }
            menuChoice("Read", icon: readIcon, isOn: filters.playedFilter == .read) {
                filters.togglePlayedFilter(.read)
            }
            Divider()
            menuChoice("Reading", icon: readingIcon, isOn: filters.readingOnly) {
                filters.setReadingOnly(!filters.readingOnly)
            }
            menuChoice("Downloaded", icon: downloadedIcon, isOn: filters.downloadedOnly) {
                filters.downloadedOnly.toggle()
            }
            menuChoice("Favorites", icon: favoriteIcon, isOn: filters.favoritesOnly) {
                filters.favoritesOnly.toggle()
            }
        }
    }

    /// A toolbar menu behind one icon button, showing the icon's accented
    /// form while highlighted.
    private func toolbarMenu(_ icon: Icon, help: LocalizedStringKey, isHighlighted: Bool = false, @ViewBuilder choices: () -> some View) -> some View {
        Menu {
            choices()
        } label: {
            if isHighlighted {
                icon.accented
            } else {
                icon.plain
            }
        }
        .menuIndicator(.hidden)
        .help(help)
    }

    /// One choice in a menu: its icon shows its accented image while the
    /// choice is active, in place of the system check mark.
    private func menuChoice(_ title: LocalizedStringKey, icon: Icon, isOn: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label {
                Text(title)
            } icon: {
                isOn ? icon.accentedImage(in: environment) : icon.plain
            }
        }
    }
}

/// The library list's empty states: loading, a failed first load, an empty
/// library, or no books passing the search and filters, titled by what
/// there is none of. A refresh failure keeps the current list; these only
/// cover an empty one.
public struct LibraryEmptyOverlay: View {
    let list: BookList
    let scope: BookGroup?
    let filters: LibraryFilters

    @Environment(Library.self) private var library
    @Environment(PlayerController.self) private var player

    public init(_ list: BookList, scope: BookGroup?, filters: LibraryFilters) {
        self.list = list
        self.scope = scope
        self.filters = filters
    }

    public var body: some View {
        if library.books.isEmpty {
            if library.isLoading {
                ProgressView()
            } else if let message = library.errorMessage {
                ContentUnavailableView("Cannot load the library", systemImage: "exclamationmark.triangle", description: Text(message))
            } else {
                ContentUnavailableView("No Books", systemImage: "books.vertical")
            }
        } else if !list.hasVisibleContent {
            ContentUnavailableView(emptyTitle, systemImage: "magnifyingglass")
        }
    }

    /// The title naming what the search and filters left none of.
    private var emptyTitle: String {
        library.emptyListTitle(in: scope, filters: filters, loadedBookID: player.book?.id)
    }
}
