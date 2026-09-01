import JellyBlairKit
import SwiftUI

/// The book list, grouped by author, with navigation to each book's screen.
struct LibraryScreen: View {
    let session: AppSession
    let library: LibraryViewModel
    let player: PlayerController

    @State private var isShowingSettings = false

    var body: some View {
        List {
            ForEach(library.authorGroups) { group in
                Section(group.name) {
                    ForEach(group.books) { book in
                        NavigationLink(value: book) {
                            BookRow(
                                book: book,
                                imageURL: library.client.imageURL(for: book),
                                isLoaded: book.id == player.book?.id
                            )
                        }
                    }
                }
            }
        }
        .navigationTitle("Audiobooks")
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
