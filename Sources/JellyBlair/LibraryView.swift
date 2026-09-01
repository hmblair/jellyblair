import JellyBlairKit
import SwiftUI

/// Sidebar list of audiobooks, grouped by author.
struct LibraryView: View {
    @Binding var selection: String?

    @Environment(LibraryViewModel.self) private var library
    @Environment(PlayerController.self) private var player

    @State private var searchQuery = ""

    private var visibleGroups: [AuthorGroup] {
        library.authorGroups(matching: searchQuery)
    }

    var body: some View {
        List(selection: $selection) {
            ForEach(visibleGroups) { group in
                Section(group.name) {
                    ForEach(group.books) { book in
                        BookRow(book: book, isLoaded: book.id == player.book?.id)
                            .tag(book.id)
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .navigationTitle("Audiobooks")
        .searchable(text: $searchQuery, placement: .sidebar, prompt: "Search")
        .overlay {
            // A refresh failure keeps the current list; overlays only cover an empty one.
            if library.books.isEmpty {
                if library.isLoading {
                    ProgressView()
                } else if let message = library.errorMessage {
                    ContentUnavailableView("Cannot load the library", systemImage: "exclamationmark.triangle", description: Text(message))
                }
            } else if visibleGroups.isEmpty {
                ContentUnavailableView.search(text: searchQuery)
            }
        }
    }
}
