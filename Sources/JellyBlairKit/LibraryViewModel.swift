import Foundation
import Observation

/// A named shelf of books: one author's or one narrator's.
public struct BookGroup: Identifiable, Hashable {
    public enum Kind: Hashable {
        case author
        case narrator
    }

    public let name: String
    public let kind: Kind
    public let books: [Book]

    public var id: String { "\(kind):\(name)" }

    public var roleLabel: String {
        switch kind {
        case .author:
            return "Author"
        case .narrator:
            return "Narrator"
        }
    }
}

/// Holds the audiobook list and its sidebar grouping by author.
@MainActor
@Observable
public final class LibraryViewModel {
    public let client: JellyfinClient

    public private(set) var books: [Book] = []
    public private(set) var authorGroups: [BookGroup] = []
    public private(set) var narratorGroups: [BookGroup] = []
    public private(set) var isLoading = true
    public private(set) var errorMessage: String?

    public init(client: JellyfinClient) {
        self.client = client
    }

    public func load() async {
        isLoading = true
        errorMessage = nil
        do {
            books = try await client.fetchAudiobooks()
            authorGroups = Self.group(books, kind: .author, by: { $0.author ?? "Unknown Author" })
            narratorGroups = Self.group(books.filter { $0.narrator != nil }, kind: .narrator, by: { $0.narrator ?? "" })
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }

    /// Groups filtered to books whose title, author, or narrator contains
    /// the query, keeping their author headings. An empty query passes all.
    public func authorGroups(matching query: String) -> [BookGroup] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return authorGroups }
        return authorGroups.compactMap { group in
            let matches = group.books.filter { $0.matches(trimmed) }
            guard !matches.isEmpty else { return nil }
            return BookGroup(name: group.name, kind: group.kind, books: matches)
        }
    }

    /// One author's books, filtered by the query when it is not empty.
    public func books(in group: BookGroup, matching query: String) -> [Book] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return group.books }
        return group.books.filter { $0.matches(trimmed) }
    }

    /// Groups books under a derived name. Books keep the server's title order
    /// within each group, and names sort ignoring a leading article.
    private static func group(_ books: [Book], kind: BookGroup.Kind, by name: (Book) -> String) -> [BookGroup] {
        var grouped: [String: [Book]] = [:]
        for book in books {
            grouped[name(book), default: []].append(book)
        }
        return grouped.keys
            .sorted { sortKey($0).localizedStandardCompare(sortKey($1)) == .orderedAscending }
            .map { BookGroup(name: $0, kind: kind, books: grouped[$0]!) }
    }

    private static func sortKey(_ name: String) -> String {
        for article in ["The ", "A ", "An "] where name.hasPrefix(article) {
            return String(name.dropFirst(article.count))
        }
        return name
    }
}
