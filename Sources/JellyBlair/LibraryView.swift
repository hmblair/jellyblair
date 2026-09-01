import JellyBlairKit
import SwiftUI

/// Sidebar list of audiobooks with cover art and runtime.
struct LibraryView: View {
    let library: LibraryViewModel
    @Binding var selection: String?
    let loadedBookID: String?

    var body: some View {
        List(selection: $selection) {
            ForEach(library.authorGroups) { group in
                Section(group.name) {
                    ForEach(group.books) { book in
                        BookRow(
                            book: book,
                            imageURL: library.client.imageURL(for: book),
                            isLoaded: book.id == loadedBookID
                        )
                        .tag(book.id)
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .navigationTitle("Audiobooks")
        .overlay {
            // A refresh failure keeps the current list; overlays only cover an empty one.
            if library.books.isEmpty {
                if library.isLoading {
                    ProgressView()
                } else if let message = library.errorMessage {
                    ContentUnavailableView("Cannot load the library", systemImage: "exclamationmark.triangle", description: Text(message))
                }
            }
        }
    }
}

