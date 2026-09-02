import JellyBlairKit
import SwiftUI

/// The book list, grouped by author, narrator, or genre, with navigation to
/// each book's screen. With a scope it shows that one group's books instead.
/// A floating bar holds the search field, the grouping toggle, and the
/// downloaded-only filter; rows fade out beneath it as they scroll up.
struct LibraryScreen: View {
    let session: AppSession
    var scope: BookGroup?

    @Environment(LibraryViewModel.self) private var library
    @Environment(PlayerController.self) private var player
    @Environment(BookCatalog.self) private var catalog
    @Environment(\.openAuthor) private var openAuthor
    @Environment(\.openNarrator) private var openNarrator
    @Environment(\.openGenre) private var openGenre

    @State private var isShowingSettings = false
    @State private var searchQuery = ""
    @State private var showDownloadedOnly = false

    /// Height of the region the floating bar occupies over the list.
    private static let barZoneHeight: CGFloat = 34

    private var visibleGroups: [BookGroup] {
        library.groups(matching: searchQuery).compactMap { group in
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
                if scope == nil {
                    groupToggle
                }
                filterToggle
            }
            .padding(.horizontal, 20)
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if scope == nil {
                Button {
                    isShowingSettings = true
                } label: {
                    Image(systemName: "gearshape")
                }
            }
        }
        .sheet(isPresented: $isShowingSettings) {
            SettingsScreen(session: session)
        }
    }

    private var bookList: some View {
        List {
            if let scope {
                Section {
                    ForEach(filteredBooks(library.books(in: scope, matching: searchQuery))) { book in
                        BookRowLink(book: book)
                    }
                } header: {
                    GroupHeading(name: scope.name, iconName: scope.iconName)
                }
            } else {
                ForEach(visibleGroups) { group in
                    Section {
                        ForEach(group.books) { book in
                            BookRowLink(book: book)
                        }
                    } header: {
                        GroupHeading(name: group.name) {
                            openGroup(group)
                        }
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
            } else if scope == nil, visibleGroups.isEmpty {
                ContentUnavailableView.search(text: searchQuery)
            }
        }
    }

    private func filteredBooks(_ books: [Book]) -> [Book] {
        guard showDownloadedOnly else { return books }
        return books.filter { catalog.isDownloaded($0) }
    }

    /// Navigates to a group through the action for its role.
    private func openGroup(_ group: BookGroup) {
        switch group.kind {
        case .author:
            openAuthor?(group.name)
        case .narrator:
            openNarrator?(group.name)
        case .genre:
            openGenre?(group.name)
        }
    }

    /// Cycles the library grouping through author, narrator, and genre.
    private var groupToggle: some View {
        Button {
            library.groupKind = library.groupKind.next
        } label: {
            Image(systemName: library.groupKind.iconName)
                .font(.callout)
                .foregroundStyle(.secondary)
                .padding(.vertical, 7)
                .padding(.horizontal, 9)
                .background(
                    Capsule()
                        .fill(Color.primary.opacity(0.06))
                )
        }
        .buttonStyle(.plain)
    }

    private var filterToggle: some View {
        Button {
            showDownloadedOnly.toggle()
        } label: {
            // Unselected, the icon wears the search capsule's own tone,
            // with the arrow in the capsule's placeholder gray.
            Image(systemName: "arrow.down.circle.fill")
                .font(.system(size: 27))
                .symbolRenderingMode(.palette)
                .foregroundStyle(
                    showDownloadedOnly ? Color.white : Color.secondary,
                    showDownloadedOnly ? Color.green : Color.primary.opacity(0.06)
                )
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
