import JellyBlairKit
import SwiftUI

/// Sidebar list of audiobooks. Shows the full library grouped by author, or
/// one author's books after their heading is clicked, with a back row.
/// A floating bar holds the search field and the downloaded-only filter;
/// rows fade out beneath it as they scroll up.
struct LibraryView: View {
    @Binding var selection: String?
    @Binding var scope: BookGroup?

    @Environment(LibraryViewModel.self) private var library
    @Environment(PlayerController.self) private var player
    @Environment(BookCatalog.self) private var catalog

    @State private var searchQuery = ""
    @State private var showDownloadedOnly = false
    @State private var isHoveringFilter = false

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
            .padding(.horizontal, 10)
        }
        .navigationTitle("Audiobooks")
    }

    private var bookList: some View {
        List(selection: $selection) {
            if let scope {
                backRow(to: scope)
                ForEach(filteredBooks(library.books(in: scope, matching: searchQuery))) { book in
                    row(for: book)
                }
            } else {
                ForEach(visibleGroups) { group in
                    Section {
                        ForEach(group.books) { book in
                            row(for: book)
                        }
                    } header: {
                        AuthorHeading(name: group.name) {
                            enterScope(group)
                        }
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .top, spacing: 0) {
            Color.clear.frame(height: Self.barZoneHeight + 6)
        }
        .overlay {
            // A refresh failure keeps the current list; overlays only cover an empty one.
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

    private var filterToggle: some View {
        Button {
            showDownloadedOnly.toggle()
        } label: {
            Image(systemName: showDownloadedOnly ? "arrow.down.circle.fill" : "arrow.down.circle")
                .font(.title2)
                .foregroundStyle(showDownloadedOnly ? Color.green : Color.secondary)
                .opacity(isHoveringFilter ? 0.6 : 1)
                .animation(.easeOut(duration: 0.1), value: isHoveringFilter)
        }
        .buttonStyle(.plain)
        .onHover { isHoveringFilter = $0 }
        .help(showDownloadedOnly ? "Show all books" : "Show only downloaded books")
    }

    private func row(for book: Book) -> some View {
        BookRow(book: book, isLoaded: book.id == player.book?.id)
            .tag(book.id)
    }

    private func backRow(to scope: BookGroup) -> some View {
        Button {
            exitScope()
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "chevron.left")
                    .font(.caption)
                Text(scope.name)
                    .fontWeight(.semibold)
                Text("(\(scope.roleLabel))")
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func enterScope(_ group: BookGroup) {
        searchQuery = ""
        // The clicked group can be a filtered subset; scope to the full one.
        scope = library.authorGroups.first { $0.name == group.name } ?? group
    }

    private func exitScope() {
        searchQuery = ""
        scope = nil
    }
}
