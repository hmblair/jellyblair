import JellyBlairKit
import SwiftUI

/// Sidebar list of audiobooks. Shows the full library grouped by author,
/// narrator, or genre, or one group's books after its heading is clicked.
/// A floating bar holds the search field, the grouping toggle, and the
/// downloaded-only filter; rows fade out beneath it as they scroll up.
struct LibraryView: View {
    @Binding var selection: String?
    @Binding var scope: BookGroup?

    @Environment(LibraryViewModel.self) private var library
    @Environment(PlayerController.self) private var player
    @Environment(BookCatalog.self) private var catalog

    @State private var searchQuery = ""
    @State private var showDownloadedOnly = false
    @State private var isHoveringFilter = false
    @State private var isHoveringGroupToggle = false

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
            .padding(.horizontal, 10)
        }
        .navigationTitle("Audiobooks")
    }

    private var bookList: some View {
        List(selection: $selection) {
            if let scope {
                Section {
                    ForEach(filteredBooks(library.books(in: scope, matching: searchQuery))) { book in
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

    /// Cycles the library grouping through author, narrator, and genre.
    private var groupToggle: some View {
        Button {
            library.groupKind = library.groupKind.next
        } label: {
            Image(systemName: library.groupKind.iconName)
                .font(.callout)
                .foregroundStyle(.secondary)
                .padding(.vertical, 5)
                .padding(.horizontal, 8)
                .background(
                    Capsule()
                        .fill(Color.primary.opacity(isHoveringGroupToggle ? 0.12 : 0.06))
                        .animation(.easeOut(duration: 0.1), value: isHoveringGroupToggle)
                )
        }
        .buttonStyle(.plain)
        .onHover { isHoveringGroupToggle = $0 }
        .help("Change the grouping")
    }

    private var filterToggle: some View {
        Button {
            showDownloadedOnly.toggle()
        } label: {
            // Unselected, the icon wears the search capsule's own tone,
            // with the arrow in the capsule's placeholder gray.
            Image(systemName: "arrow.down.circle.fill")
                .font(.system(size: 24))
                .symbolRenderingMode(.palette)
                .foregroundStyle(
                    showDownloadedOnly ? Color.white : Color.secondary,
                    showDownloadedOnly ? Color.green : Color.primary.opacity(isHoveringFilter ? 0.12 : 0.06)
                )
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
