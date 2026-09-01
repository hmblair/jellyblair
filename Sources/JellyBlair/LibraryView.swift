import JellyBlairKit
import SwiftUI

/// Sidebar list of audiobooks. Shows the full library grouped by author, or
/// one author's books after their heading is clicked, with a back row.
struct LibraryView: View {
    @Binding var selection: String?
    @Binding var scope: BookGroup?

    @Environment(LibraryViewModel.self) private var library
    @Environment(PlayerController.self) private var player

    @State private var searchQuery = ""

    private var visibleGroups: [BookGroup] {
        library.authorGroups(matching: searchQuery)
    }

    var body: some View {
        List(selection: $selection) {
            if let scope {
                backRow(to: scope)
                ForEach(library.books(in: scope, matching: searchQuery)) { book in
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
            } else if scope == nil, visibleGroups.isEmpty {
                ContentUnavailableView.search(text: searchQuery)
            }
        }
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
