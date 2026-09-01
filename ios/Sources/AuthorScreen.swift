import JellyBlairKit
import SwiftUI

/// One author's books, with a search field scoped to them.
struct AuthorScreen: View {
    let group: AuthorGroup

    @Environment(LibraryViewModel.self) private var library
    @Environment(PlayerController.self) private var player

    @State private var searchQuery = ""

    private var visibleBooks: [Book] {
        library.books(in: group, matching: searchQuery)
    }

    var body: some View {
        List(visibleBooks) { book in
            NavigationLink(value: LibraryRoute.book(book)) {
                BookRow(book: book, isLoaded: book.id == player.book?.id)
            }
        }
        .navigationTitle(group.name)
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $searchQuery, placement: .navigationBarDrawer(displayMode: .automatic), prompt: "Search")
        .overlay {
            if visibleBooks.isEmpty {
                ContentUnavailableView.search(text: searchQuery)
            }
        }
    }
}
