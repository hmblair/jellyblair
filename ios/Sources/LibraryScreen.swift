import JellyBlairKit
import SwiftUI

/// The book list, grouped by author, with navigation to each book's screen.
struct LibraryScreen: View {
    let session: AppSession

    @Environment(LibraryViewModel.self) private var library
    @Environment(PlayerController.self) private var player

    @State private var isShowingSettings = false
    @State private var searchQuery = ""

    private var visibleGroups: [AuthorGroup] {
        library.authorGroups(matching: searchQuery)
    }

    var body: some View {
        List {
            ForEach(visibleGroups) { group in
                Section(group.name) {
                    ForEach(group.books) { book in
                        NavigationLink(value: book) {
                            BookRow(book: book, isLoaded: book.id == player.book?.id)
                        }
                    }
                }
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $searchQuery, placement: .navigationBarDrawer(displayMode: .automatic), prompt: "Search")
        .refreshable {
            await library.load()
        }
        .overlay {
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
        .toolbar {
            Button {
                isShowingSettings = true
            } label: {
                Image(systemName: "gearshape")
            }
        }
        .sheet(isPresented: $isShowingSettings) {
            SettingsScreen(session: session)
        }
    }
}
