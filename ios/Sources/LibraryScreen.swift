import JellyBlairKit
import SwiftUI

/// The book list, grouped by author, with navigation to each book's screen.
/// A floating bar holds the search field and the downloaded-only filter;
/// rows fade out beneath it as they scroll up.
struct LibraryScreen: View {
    let session: AppSession

    @Environment(LibraryViewModel.self) private var library
    @Environment(PlayerController.self) private var player
    @Environment(BookCatalog.self) private var catalog
    @Environment(\.openAuthor) private var openAuthor

    @State private var isShowingSettings = false
    @State private var searchQuery = ""
    @State private var showDownloadedOnly = false

    /// Height of the region the floating bar occupies over the list.
    private static let barZoneHeight: CGFloat = 34

    private var visibleGroups: [BookGroup] {
        library.authorGroups(matching: searchQuery).compactMap { group in
            showDownloadedOnly ? group.keeping { catalog.isDownloaded($0) } : group
        }
    }

    var body: some View {
        ZStack(alignment: .top) {
            bookList
                .mask(
                    VStack(spacing: 0) {
                        Color.clear
                            .frame(height: Self.barZoneHeight)
                        LinearGradient(colors: [.clear, .black], startPoint: .top, endPoint: .bottom)
                            .frame(height: 22)
                        Rectangle()
                    }
                )

            HStack(spacing: 8) {
                CapsuleSearchField("Search", text: $searchQuery)
                filterToggle
            }
            .padding(.horizontal, 20)
        }
        .navigationBarTitleDisplayMode(.inline)
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

    private var bookList: some View {
        List {
            ForEach(visibleGroups) { group in
                Section {
                    ForEach(group.books) { book in
                        BookRowLink(book: book)
                    }
                } header: {
                    AuthorHeading(name: group.name) {
                        openAuthor?(group.name)
                    }
                }
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            Color.clear.frame(height: Self.barZoneHeight + 6)
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
            } else if visibleGroups.isEmpty {
                ContentUnavailableView.search(text: searchQuery)
            }
        }
    }

    private var filterToggle: some View {
        Button {
            showDownloadedOnly.toggle()
        } label: {
            Image(systemName: showDownloadedOnly ? "arrow.down.circle.fill" : "arrow.down.circle")
                .font(.title2)
                .foregroundStyle(showDownloadedOnly ? Color.green : Color.secondary)
        }
        .buttonStyle(.plain)
    }
}

/// A book row navigating through the explicit action rather than a value
/// link, whose rows stay highlighted while their value is in the path.
struct BookRowLink: View {
    let book: Book

    @Environment(PlayerController.self) private var player
    @Environment(\.openBook) private var openBook

    var body: some View {
        Button {
            openBook?(book)
        } label: {
            HStack {
                BookRow(book: book, isLoaded: book.id == player.book?.id)
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
        }
        .buttonStyle(.plain)
    }
}
