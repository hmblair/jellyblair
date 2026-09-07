import JellyBlairKit
import SwiftUI

/// Sidebar list of audiobooks. Shows the full library grouped by author,
/// narrator, or genre, or one group's books after its heading is clicked.
struct LibraryView: View {
    @Binding var selection: String?
    @Binding var scope: BookGroup?

    @Environment(LibraryViewModel.self) private var library
    @Environment(PlayerController.self) private var player
    @Environment(BookCatalog.self) private var catalog

    @State private var filters = LibraryFilters()

    private var visibleBooks: [Book] {
        library.visibleBooks(filters: filters, catalog: catalog)
    }

    var body: some View {
        bookList
            .searchable(text: $filters.searchQuery, placement: .sidebar, prompt: "Search")
            .navigationTitle("Audiobooks")
            .toolbar {
                LibraryFilterToolbarButtons(filters: $filters)
            }
    }

    private var bookList: some View {
        List(selection: $selection) {
            if let scope {
                Section {
                    ForEach(library.visibleBooks(in: scope, filters: filters, catalog: catalog)) { book in
                        row(for: book)
                    }
                } header: {
                    GroupHeading(name: scope.name, iconName: scope.iconName, showsBackChevron: true) {
                        exitScope()
                    }
                }
            } else {
                ForEach(visibleBooks) { book in
                    row(for: book)
                }
            }
        }
        .listStyle(.sidebar)
        .overlay {
            LibraryEmptyOverlay(hasVisibleContent: scope != nil || !visibleBooks.isEmpty, searchQuery: filters.searchQuery)
        }
    }

    private func row(for book: Book) -> some View {
        BookRow(book: book, isLoaded: book.id == player.book?.id)
            .tag(book.id)
    }

    private func exitScope() {
        filters.searchQuery = ""
        scope = nil
    }
}
