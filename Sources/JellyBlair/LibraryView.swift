import SwiftUI

/// Sidebar list of audiobooks with cover art and runtime.
struct LibraryView: View {
    let library: LibraryViewModel
    @Binding var selection: Book?

    var body: some View {
        List(library.books, selection: $selection) { book in
            BookRow(book: book, imageURL: library.client.imageURL(for: book))
                .tag(book)
        }
        .listStyle(.sidebar)
        .navigationTitle("Audiobooks")
        .overlay {
            if library.isLoading {
                ProgressView()
            } else if let message = library.errorMessage {
                ContentUnavailableView("Cannot load the library", systemImage: "exclamationmark.triangle", description: Text(message))
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
                Text(formatTime(book.runTimeSeconds))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }
}
