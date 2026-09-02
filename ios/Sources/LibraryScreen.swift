import JellyBlairKit
import SwiftUI

/// The book list, grouped by author, narrator, or genre, with navigation to
/// each book's screen. With a scope it shows that one group's books instead.
/// The shared filter bar floats over the list; rows fade out beneath it.
struct LibraryScreen: View {
    let session: AppSession
    var scope: BookGroup?

    @Environment(LibraryViewModel.self) private var library
    @Environment(BookCatalog.self) private var catalog
    @Environment(\.openAuthor) private var openAuthor
    @Environment(\.openNarrator) private var openNarrator
    @Environment(\.openGenre) private var openGenre

    @State private var isShowingSettings = false
    @State private var searchQuery = ""
    @State private var showDownloadedOnly = false

    private var visibleGroups: [BookGroup] {
        library.visibleGroups(matching: searchQuery, downloadedOnly: showDownloadedOnly, catalog: catalog)
    }

    var body: some View {
        ZStack(alignment: .top) {
            bookList
                .fadedUnderFloatingBar()

            LibraryFilterBar(
                searchQuery: $searchQuery,
                showDownloadedOnly: $showDownloadedOnly,
                showsGroupToggle: scope == nil
            )
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
                    ForEach(library.visibleBooks(in: scope, matching: searchQuery, downloadedOnly: showDownloadedOnly, catalog: catalog)) { book in
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
            Color.clear.frame(height: floatingBarZoneHeight + 6)
        }
        .refreshable {
            await library.load()
        }
        .overlay {
            LibraryEmptyOverlay(hasVisibleContent: scope != nil || !visibleGroups.isEmpty, searchQuery: searchQuery)
        }
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
