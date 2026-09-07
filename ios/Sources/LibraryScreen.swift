import JellyBlairKit
import SwiftUI

/// The book list, grouped by author, narrator, or genre, with navigation to
/// each book's screen. With a scope it shows that one group's books instead.
struct LibraryScreen: View {
    let session: AppSession
    var scope: BookGroup?

    @Environment(LibraryViewModel.self) private var library
    @Environment(BookCatalog.self) private var catalog

    @State private var isShowingSettings = false
    @State private var filters = LibraryFilters()

    private var visibleBooks: [Book] {
        library.visibleBooks(filters: filters, catalog: catalog)
    }

    var body: some View {
        bookList
            .searchable(text: $filters.searchQuery, placement: .navigationBarDrawer(displayMode: .always))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    LibraryFilterToolbarButtons(filters: $filters)
                    if scope == nil {
                        Button {
                            isShowingSettings = true
                        } label: {
                            Image(systemName: "gearshape")
                        }
                    }
                }
            }
            .sheet(isPresented: $isShowingSettings) {
                SettingsScreen(session: session)
            }
    }

    private var bookList: some View {
        List {
            if let scope {
                Section {
                    ForEach(library.visibleBooks(in: scope, filters: filters, catalog: catalog)) { book in
                        BookRowLink(book: book)
                    }
                } header: {
                    GroupHeading(name: scope.name, iconName: scope.iconName)
                }
            } else {
                ForEach(visibleBooks) { book in
                    BookRowLink(book: book)
                }
            }
        }
        .refreshable {
            await library.load()
        }
        .overlay {
            LibraryEmptyOverlay(hasVisibleContent: scope != nil || !visibleBooks.isEmpty, searchQuery: filters.searchQuery)
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
    }
}
