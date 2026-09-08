import JellyBlairKit
import SwiftUI

/// The book list, grouped by author, narrator, or genre, with navigation to
/// each book's screen. With a scope it shows that one group's books instead.
struct LibraryScreen: View {
    var scope: BookGroup?

    @Environment(LibraryViewModel.self) private var library
    @Environment(BookCatalog.self) private var catalog
    @Environment(PlayerController.self) private var player

    @State private var filters = LibraryFilters()

    private var list: BookList {
        library.visibleList(in: scope, filters: filters, catalog: catalog, loadedBookID: player.book?.id)
    }

    var body: some View {
        bookList
            .searchable(text: $filters.searchQuery, placement: .navigationBarDrawer(displayMode: .always))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    LibraryFilterToolbarButtons(filters: $filters)
                    SettingsToolbarButton()
                }
            }
    }

    private var bookList: some View {
        List {
            if let heading = list.heading {
                Section {
                    rows
                } header: {
                    GroupHeading(heading)
                }
            } else {
                rows
            }
        }
        .listStyle(.plain)
        .scrolledToTopOnSortChange(list, filters: filters)
        .refreshable {
            await library.load()
        }
        .overlay {
            LibraryEmptyOverlay(list)
        }
    }

    private var rows: some View {
        ForEach(list.books) { book in
            BookRowLink(book: book)
        }
    }
}

/// A book row navigating through the explicit action rather than a value
/// link, whose rows stay highlighted while their value is in the path.
struct BookRowLink: View {
    let book: Book

    @Environment(PlayerController.self) private var player
    @Environment(\.openBook) private var openBook

    var body: some View {
        Button {
            openBook?(book)
        } label: {
            HStack {
                BookRow(book: book, isLoaded: book.id == player.book?.id)
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
        }
        .buttonStyle(.plain)
        .contextMenu {
            BookActionsMenuItems(book: book)
        }
    }
}
