import JellyBlairKit
import SwiftUI

/// The book list, grouped by author, with navigation to each book's screen.
struct LibraryScreen: View {
    let session: AppSession

    @Environment(LibraryViewModel.self) private var library
    @Environment(\.openAuthor) private var openAuthor
    @Environment(PlayerController.self) private var player

    @State private var isShowingSettings = false
    @State private var searchQuery = ""

    private var visibleGroups: [BookGroup] {
        library.authorGroups(matching: searchQuery)
    }

    var body: some View {
        List {
            ForEach(visibleGroups) { group in
                Section {
                    ForEach(group.books) { book in
                        NavigationLink(value: LibraryRoute.book(book)) {
                            BookRow(book: book, isLoaded: book.id == player.book?.id)
                        }
                    }
                } header: {
                    AuthorHeading(name: group.name) {
                        openAuthor?(group.name)
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
