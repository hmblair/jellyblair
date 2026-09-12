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

/// Ties a library list's identity to the sort order, so each order shows a
/// fresh list, which starts at the top.
private struct ScrollToTopOnSortChange: ViewModifier {
    let sortOrder: BookSortOrder

    func body(content: Content) -> some View {
        content.id(sortOrder)
    }
}

public extension View {
    /// Keeps a library list at its top through a change of sort order.
    func scrolledToTopOnSortChange(filters: LibraryFilters) -> some View {
        modifier(ScrollToTopOnSortChange(sortOrder: filters.sortOrder))
    }
}

/// The library's sort menu and filter menu for a toolbar. Both menus mark
/// the active choices by coloring their icons accent instead of showing
/// check marks. The filter menu's own button also colors while any filter
/// is on; the sort menu's keeps one color in every order. The in-progress
/// filter also puts the list in last-played order.
public struct LibraryFilterToolbarButtons: View {
    @Binding var filters: LibraryFilters

    public init(filters: Binding<LibraryFilters>) {
        _filters = filters
    }

    public var body: some View {
        sortMenu
        filterMenu
    }

    private var sortMenu: some View {
        toolbarMenu("arrow.up.arrow.down.circle.fill", isActive: false, help: "Sort the books") {
            ForEach(BookSortOrder.allCases) { order in
                menuChoice(order.label, icon: order.iconName, isOn: filters.sortOrder == order) {
                    filters.sortOrder = order
                }
            }
        }
    }

    private var filterMenu: some View {
        toolbarMenu("line.3.horizontal.decrease.circle.fill", isActive: filters.hasActiveFilter, help: "Filter the books") {
            menuChoice("In Progress", icon: "bookmark.fill", isOn: filters.inProgressOnly) {
                filters.setInProgressOnly(!filters.inProgressOnly)
            }
            menuChoice("Downloaded", icon: "square.and.arrow.down", isOn: filters.downloadedOnly) {
                filters.downloadedOnly.toggle()
            }
            menuChoice("Favorites", icon: favoriteIconName, isOn: filters.favoritesOnly) {
                filters.favoritesOnly.toggle()
            }
        }
    }

    /// A toolbar menu behind one icon button, which colors accent while
    /// the menu's choices narrow the list.
    private func toolbarMenu(_ iconName: String, isActive: Bool, help: String, @ViewBuilder choices: () -> some View) -> some View {
        Menu {
            choices()
        } label: {
            Image(systemName: iconName)
        }
        .menuIndicator(.hidden)
        .foregroundStyle(isActive ? Color.accentColor : Color.secondary)
        .help(help)
    }

    /// One choice in a menu: its icon colors accent while the choice is
    /// active, in place of the system check mark; see paletteSymbol.
    private func menuChoice(_ title: String, icon: String, isOn: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label {
                Text(title)
            } icon: {
                if isOn, let tinted = paletteSymbol(icon, color: .accent) {
                    Image(platformImage: tinted)
                } else {
                    Image(systemName: icon)
                }
            }
        }
    }
}

/// The library list's empty states: loading, a failed first load, or no
/// books passing the search and filters. A refresh failure keeps the
/// current list; these only cover an empty one.
public struct LibraryEmptyOverlay: View {
    let list: BookList

    @Environment(Library.self) private var library

    public init(_ list: BookList) {
        self.list = list
    }

    public var body: some View {
        if library.books.isEmpty {
            if library.isLoading {
                ProgressView()
            } else if let message = library.errorMessage {
                ContentUnavailableView("Cannot load the library", systemImage: "exclamationmark.triangle", description: Text(message))
            }
        } else if !list.hasVisibleContent {
            // Emptiness can come from the search or the filter toggles, so
            // the message stays generic.
            ContentUnavailableView("No Results", systemImage: "magnifyingglass")
        }
    }
}
