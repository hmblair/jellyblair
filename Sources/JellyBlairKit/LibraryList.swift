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

    @Environment(Library.self) private var library
    @Environment(PlayerController.self) private var player
    @Environment(\.layoutDensity) private var density

    @State private var filters = DefaultLibraryFilters.stored

    public init(selection: Binding<String?>, scope: Binding<BookGroup?>, isShowing: Bool = true) {
        _selection = selection
        _scope = scope
        self.isShowing = isShowing
    }

    private var list: BookList {
        library.visibleList(in: scope, filters: filters, loadedBookID: player.book?.id)
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
                switch density {
                case .regular:
                    Section {
                        rows
                    } header: {
                        GroupHeading(heading, showsBackChevron: true, action: exitScope)
                    }
                case .compact:
                    // A plain list pins its section headers over the rows,
                    // so the heading scrolls as a row of its own instead.
                    GroupHeading(heading)
                        .listRowSeparator(.hidden)
                        .selectionDisabled()
                    rows
                }
            } else {
                rows
            }
        }
        .libraryListStyle()
        .scrolledToTopOnSortChange(filters: filters)
        .refreshable {
            await library.load()
        }
        .overlay {
            LibraryEmptyOverlay(list, scope: scope, filters: filters)
        }
    }

    private var rows: some View {
        ForEach(list.sections) { section in
            if let title = section.title {
                sectionTitle(title)
            }
            ForEach(section.books) { book in
                row(for: book)
                    .bookActionsContextMenu(for: book)
            }
        }
    }

    /// A role title between a person's rows, as a quiet row of its own
    /// that a selection passes over.
    private func sectionTitle(_ title: String) -> some View {
        Text(verbatim: title)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.secondary)
            .selectionDisabled()
            .padding(.top, 8)
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
