import JellyBlairKit
import SwiftUI

/// Sidebar list of audiobooks. Shows the full library grouped by author, or
/// one author's books after their heading is clicked, with a back row.
struct LibraryView: View {
    @Binding var selection: String?
    @Binding var authorScope: AuthorGroup?

    @Environment(LibraryViewModel.self) private var library
    @Environment(PlayerController.self) private var player

    @State private var searchQuery = ""

    private var visibleGroups: [AuthorGroup] {
        library.authorGroups(matching: searchQuery)
    }

    var body: some View {
        List(selection: $selection) {
            if let authorScope {
                backRow(to: authorScope)
                ForEach(library.books(in: authorScope, matching: searchQuery)) { book in
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
        .navigationTitle("Audiobooks")
        .searchable(text: $searchQuery, placement: .sidebar, prompt: "Search")
        .overlay {
            // A refresh failure keeps the current list; overlays only cover an empty one.
            if library.books.isEmpty {
                if library.isLoading {
                    ProgressView()
                } else if let message = library.errorMessage {
                    ContentUnavailableView("Cannot load the library", systemImage: "exclamationmark.triangle", description: Text(message))
                }
            } else if authorScope == nil, visibleGroups.isEmpty {
                ContentUnavailableView.search(text: searchQuery)
            }
        }
    }

    private func row(for book: Book) -> some View {
        BookRow(book: book, isLoaded: book.id == player.book?.id)
            .tag(book.id)
    }



    private func backRow(to scope: AuthorGroup) -> some View {
        Button {
            exitScope()
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "chevron.left")
                    .font(.caption)
                Text(scope.name)
                    .fontWeight(.semibold)
                Spacer()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func enterScope(_ group: AuthorGroup) {
        searchQuery = ""
        // The clicked group can be a filtered subset; scope to the full one.
        authorScope = library.authorGroups.first { $0.name == group.name } ?? group
    }

    private func exitScope() {
        searchQuery = ""
        authorScope = nil
    }
}
