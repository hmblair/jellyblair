import SwiftUI

/// The library's book list, grouped by author, narrator or genre, or showing
/// one group's books after its heading is opened. It reports the reader's
/// choice through the selection binding: a regular layout fills its detail
/// pane from it, and a compact layout pushes the book's screen.
public struct LibraryList: View {
    @Binding var selection: String?
    @Binding var scope: BookGroup?
    /// True while the list is on screen. The sort menu and the filter toggles
    /// act on this list, so they leave the toolbar when the list does.
    let isShowing: Bool

    @Environment(LibraryViewModel.self) private var library
    @Environment(PlayerController.self) private var player
    @Environment(BookCatalog.self) private var catalog
    @Environment(\.layoutDensity) private var density

    @State private var filters = LibraryFilters()

    public init(selection: Binding<String?>, scope: Binding<BookGroup?>, isShowing: Bool = true) {
        _selection = selection
        _scope = scope
        self.isShowing = isShowing
    }

    private var list: BookList {
        library.visibleList(in: scope, filters: filters, catalog: catalog, loadedBookID: player.book?.id)
    }

    public var body: some View {
        bookList
            .libraryListChrome(searchQuery: $filters.searchQuery)
            .toolbar {
                if isShowing {
                    LibraryFilterToolbarButtons(filters: $filters)
                }
                // When regular the book screen carries the settings button,
                // and there is always a screen beside the list to carry it.
                if density == .compact {
                    SettingsToolbarButton()
                }
            }
    }

    private var bookList: some View {
        List(selection: $selection) {
            if let heading = list.heading {
                Section {
                    rows
                } header: {
                    GroupHeading(heading, showsBackChevron: exitsScopeInPlace, action: exitsScopeInPlace ? exitScope : nil)
                }
            } else {
                rows
            }
        }
        .libraryListStyle()
        .scrolledToTopOnSortChange(list, filters: filters)
        .refreshable {
            await library.load()
        }
        .overlay {
            LibraryEmptyOverlay(list)
        }
    }

    /// A regular list swaps its scope in place, so its heading carries the
    /// way back out. A compact list was pushed onto a stack, which has one.
    private var exitsScopeInPlace: Bool {
        density == .regular
    }

    private var rows: some View {
        ForEach(list.books) { book in
            row(for: book)
                .contextMenu {
                    BookActionsMenuItems(book: book)
                }
        }
    }

    /// A regular list reports the choice through the list's own selection. A
    /// compact list cannot, since a tap outside edit mode leaves an untagged
    /// row alone, so its rows report the choice themselves.
    @ViewBuilder
    private func row(for book: Book) -> some View {
        switch density {
        case .regular:
            bookRow(book)
                .tag(book.id)
        case .compact:
            Button {
                selection = book.id
            } label: {
                HStack {
                    bookRow(book)
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
            }
            .buttonStyle(.plain)
        }
    }

    private func bookRow(_ book: Book) -> some View {
        BookRow(book: book, isLoaded: book.id == player.book?.id)
    }

    private func exitScope() {
        filters.searchQuery = ""
        scope = nil
    }
}

/// The sidebar style when regular, and edge-to-edge rows when compact.
private struct LibraryListStyle: ViewModifier {
    @Environment(\.layoutDensity) private var density

    @ViewBuilder
    func body(content: Content) -> some View {
        switch density {
        case .regular:
            content.listStyle(.sidebar)
        case .compact:
            content.listStyle(.plain)
        }
    }
}

/// The list's search field and title. The sidebar names itself, while a
/// compact list is the root screen and shows no title, so its search field
/// keeps the navigation bar to itself.
private struct LibraryListChrome: ViewModifier {
    @Binding var searchQuery: String

    @Environment(\.layoutDensity) private var density

    @ViewBuilder
    func body(content: Content) -> some View {
        switch density {
        case .regular:
            content
                .searchable(text: $searchQuery, placement: .sidebar, prompt: "Search")
                .navigationTitle("Audiobooks")
        case .compact:
            compactSearchField(content)
                .inlineNavigationTitle()
        }
    }

    /// The navigation bar drawer belongs to iOS alone.
    @ViewBuilder
    private func compactSearchField(_ content: Content) -> some View {
        #if os(iOS)
        content.searchable(text: $searchQuery, placement: .navigationBarDrawer(displayMode: .always))
        #else
        content.searchable(text: $searchQuery, prompt: "Search")
        #endif
    }
}

private extension View {
    func libraryListStyle() -> some View {
        modifier(LibraryListStyle())
    }

    func libraryListChrome(searchQuery: Binding<String>) -> some View {
        modifier(LibraryListChrome(searchQuery: searchQuery))
    }
}
