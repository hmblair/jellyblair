import JellyBlairKit
import SwiftUI

/// One group's books, with a search field scoped to them.
struct BookGroupScreen: View {
    let group: BookGroup

    @Environment(LibraryViewModel.self) private var library
    @Environment(PlayerController.self) private var player

    @State private var searchQuery = ""

    private var visibleBooks: [Book] {
        library.books(in: group, matching: searchQuery)
    }

    var body: some View {
        List(visibleBooks) { book in
            BookRowLink(book: book)
        }
        .navigationTitle(group.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                HStack(spacing: 6) {
                    Image(systemName: group.iconName)
                        .imageScale(.small)
                    Text(group.name)
                        .font(.headline)
                }
            }
        }
        .searchable(text: $searchQuery, placement: .navigationBarDrawer(displayMode: .automatic), prompt: "Search")
        .overlay {
            if visibleBooks.isEmpty {
                ContentUnavailableView.search(text: searchQuery)
            }
        }
    }
}
