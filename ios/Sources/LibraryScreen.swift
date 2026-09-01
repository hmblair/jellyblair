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
                            BookRow(book: book, imageURL: library.client.imageURL(for: book))
                        }
                    }
                }
            }
        }
        .navigationTitle("Audiobooks")
        .navigationDestination(for: Book.self) { book in
            BookScreen(book: book, player: player, client: library.client)
        }
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
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if player.book != nil {
                PlayerBarView(player: player, client: library.client)
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
