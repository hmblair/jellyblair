import Foundation
import Observation

/// A sidebar section: one author and their books.
struct AuthorGroup: Identifiable {
    let name: String
    let books: [Book]

    var id: String { name }
}

/// Holds the audiobook list and its sidebar grouping by author.
@MainActor
@Observable
final class LibraryViewModel {
    let client: JellyfinClient

    private(set) var books: [Book] = []
    private(set) var authorGroups: [AuthorGroup] = []
    private(set) var isLoading = true
    private(set) var errorMessage: String?

    init(client: JellyfinClient) {
        self.client = client
    }

    func load() async {
        isLoading = true
        errorMessage = nil
        do {
            books = try await client.fetchAudiobooks()
            authorGroups = Self.groupByAuthor(books)
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }

    /// Groups books under their authors. Books keep the server's title order
    /// within each group, and authors sort ignoring a leading article.
    private static func groupByAuthor(_ books: [Book]) -> [AuthorGroup] {
        var grouped: [String: [Book]] = [:]
        for book in books {
            grouped[book.author ?? "Unknown Author", default: []].append(book)
        }
        return grouped.keys
            .sorted { sortKey($0).localizedStandardCompare(sortKey($1)) == .orderedAscending }
            .map { AuthorGroup(name: $0, books: grouped[$0]!) }
    }

    private static func sortKey(_ name: String) -> String {
        for article in ["The ", "A ", "An "] where name.hasPrefix(article) {
            return String(name.dropFirst(article.count))
        }
        return name
    }
}
