import JellyBlairKit
import SwiftUI

/// Sidebar list of audiobooks. Shows the full library grouped by author,
/// narrator, or genre, or one group's books after its heading is clicked.
struct LibraryView: View {
    @Binding var selection: String?
    @Binding var scope: BookGroup?
    /// True while the sidebar is showing. The sort menu and the filter
    /// toggles act on this list, so they leave the window's toolbar when the
    /// list does.
    let isShowing: Bool

    @Environment(LibraryViewModel.self) private var library
    @Environment(PlayerController.self) private var player
    @Environment(BookCatalog.self) private var catalog

    @State private var filters = LibraryFilters()

    private var list: BookList {
        library.visibleList(in: scope, filters: filters, catalog: catalog, loadedBookID: player.book?.id)
    }

    var body: some View {
        bookList
            .searchable(text: $filters.searchQuery, placement: .sidebar, prompt: "Search")
            .navigationTitle("Audiobooks")
            .toolbar {
                if isShowing {
                    LibraryFilterToolbarButtons(filters: $filters)
                }
            }
    }

    private var bookList: some View {
        List(selection: $selection) {
            if let heading = list.heading {
                Section {
                    rows
                } header: {
                    GroupHeading(heading, showsBackChevron: true) {
                        exitScope()
                    }
                }
            } else {
                rows
            }
        }
        .listStyle(.sidebar)
        .scrolledToTopOnSortChange(list, filters: filters)
        .overlay {
            LibraryEmptyOverlay(list)
        }
    }

    private var rows: some View {
        ForEach(list.books) { book in
            row(for: book)
        }
    }

    private func row(for book: Book) -> some View {
        BookRow(book: book, isLoaded: book.id == player.book?.id)
            .tag(book.id)
            .contextMenu {
                BookActionsMenuItems(book: book)
            }
    }

    private func exitScope() {
        filters.searchQuery = ""
        scope = nil
    }
}
