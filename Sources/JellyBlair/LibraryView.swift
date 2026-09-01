import SwiftUI

/// Sidebar list of audiobooks with cover art and runtime.
struct LibraryView: View {
    let library: LibraryViewModel
    @Binding var selection: String?

    var body: some View {
        List(library.books, selection: $selection) { book in
            BookRow(book: book, imageURL: library.client.imageURL(for: book))
                .tag(book.id)
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

struct BookRow: View {
    let book: Book
    let imageURL: URL

    var body: some View {
        HStack(spacing: 10) {
            BookCoverImage(bookID: book.id, url: imageURL, contentMode: .fill)
                .frame(width: 44, height: 44)
                .clipShape(RoundedRectangle(cornerRadius: 6))

            VStack(alignment: .leading, spacing: 2) {
                Text(book.name)
                    .lineLimit(1)
                Text(book.authorAndRuntimeText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 2)
    }
}
