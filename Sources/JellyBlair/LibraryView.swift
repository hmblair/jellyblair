import JellyBlairKit
import SwiftUI

/// Sidebar list of audiobooks. Shows the full library grouped by author,
/// narrator, or genre, or one group's books after its heading is clicked.
/// The shared filter bar floats over the list; rows fade out beneath it.
struct LibraryView: View {
    @Binding var selection: String?
    @Binding var scope: BookGroup?

    @Environment(LibraryViewModel.self) private var library
    @Environment(PlayerController.self) private var player
    @Environment(BookCatalog.self) private var catalog

    @State private var searchQuery = ""
    @State private var showDownloadedOnly = false
    @State private var showInProgressOnly = false

    private var visibleGroups: [BookGroup] {
        library.visibleGroups(matching: searchQuery, downloadedOnly: showDownloadedOnly, inProgressOnly: showInProgressOnly, catalog: catalog)
    }

    var body: some View {
        ZStack(alignment: .top) {
            bookList
                .fadedUnderFloatingBar()

            LibraryFilterBar(
                searchQuery: $searchQuery,
                showDownloadedOnly: $showDownloadedOnly,
                showInProgressOnly: $showInProgressOnly,
                showsGroupToggle: scope == nil
            )
            .padding(.horizontal, 10)
        }
        .navigationTitle("Audiobooks")
    }

    private var bookList: some View {
        List(selection: $selection) {
            if let scope {
                Section {
                    ForEach(library.visibleBooks(in: scope, matching: searchQuery, downloadedOnly: showDownloadedOnly, inProgressOnly: showInProgressOnly, catalog: catalog)) { book in
                        row(for: book)
                    }
                } header: {
                    GroupHeading(name: scope.name, iconName: scope.iconName, showsBackChevron: true) {
                        exitScope()
                    }
                }
            } else {
                ForEach(visibleGroups) { group in
                    Section {
                        ForEach(group.books) { book in
                            row(for: book)
                        }
                    } header: {
                        GroupHeading(name: group.name) {
                            enterScope(group)
                        }
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .top, spacing: 0) {
            Color.clear.frame(height: floatingBarZoneHeight + 6)
        }
        .overlay {
            LibraryEmptyOverlay(hasVisibleContent: scope != nil || !visibleGroups.isEmpty, searchQuery: searchQuery)
        }
    }

    private func row(for book: Book) -> some View {
        BookRow(book: book, isLoaded: book.id == player.book?.id)
            .tag(book.id)
    }

    private func enterScope(_ group: BookGroup) {
        searchQuery = ""
        // The clicked group can be a filtered subset; scope to the full one.
        scope = library.fullGroup(matching: group) ?? group
    }

    private func exitScope() {
        searchQuery = ""
        scope = nil
    }
}
