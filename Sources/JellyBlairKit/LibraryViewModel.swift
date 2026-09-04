import Foundation
import Observation

/// A named shelf of books: one author's, one narrator's, or one genre's.
public struct BookGroup: Identifiable, Hashable {
    public enum Kind: Hashable {
        case author
        case narrator
        case genre

        /// The kind after this one in the grouping picker's cycle.
        public var next: Kind {
            switch self {
            case .author:
                return .narrator
            case .narrator:
                return .genre
            case .genre:
                return .author
            }
        }

        /// The symbol for this role, shared by the book screen's metadata
        /// lines and the group views.
        public var iconName: String {
            switch self {
            case .author:
                return "person.fill"
            case .narrator:
                return "mic.fill"
            case .genre:
                return "tag.fill"
            }
        }
    }

    /// The symbol for the group's role.
    public var iconName: String { kind.iconName }

    public let name: String
    public let kind: Kind
    public let books: [Book]

    public var id: String { "\(kind):\(name)" }

    /// The group narrowed to books passing the predicate, or nil when none do.
    public func keeping(_ isIncluded: (Book) -> Bool) -> BookGroup? {
        let kept = books.filter(isIncluded)
        guard !kept.isEmpty else { return nil }
        return BookGroup(name: name, kind: kind, books: kept)
    }

}

/// The library list's filters, threaded whole from the filter bar to the
/// visibility functions, so a new filter touches neither platform's screen.
public struct LibraryFilters: Equatable {
    public var searchQuery = ""
    public var downloadedOnly = false
    public var inProgressOnly = false

    public init() {}
}

/// Holds the audiobook list and its sidebar grouping by author.
@MainActor
@Observable
public final class LibraryViewModel {
    public let client: JellyfinClient

    public private(set) var books: [Book] = []
    public private(set) var authorGroups: [BookGroup] = []
    public private(set) var narratorGroups: [BookGroup] = []
    public private(set) var genreGroups: [BookGroup] = []

    /// The active grouping of the library list.
    public var groupKind: BookGroup.Kind = .author

    /// The heading of books whose grouped field is missing.
    private static let unknownName = "Unknown"
    public private(set) var isLoading = true
    public private(set) var errorMessage: String?

    private let store = LibraryStore()

    public init(client: JellyfinClient) {
        self.client = client
        // The last snapshot shows immediately and carries offline launches.
        setBooks(store.load())
    }

    public func load() async {
        isLoading = true
        errorMessage = nil
        do {
            setBooks(try await client.fetchAudiobooks())
            store.save(books)
        } catch {
            // The cached snapshot stands; the overlay only shows the error
            // when there are no books at all.
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }

    private func setBooks(_ newBooks: [Book]) {
        books = newBooks
        authorGroups = Self.group(books, kind: .author, by: { [$0.author ?? Self.unknownName] })
        narratorGroups = Self.group(books, kind: .narrator, by: { book in
            let narrators = book.narrators
            return narrators.isEmpty ? [Self.unknownName] : narrators
        })
        genreGroups = Self.group(books, kind: .genre, by: { book in
            let genres = book.genres ?? []
            return genres.isEmpty ? [Self.unknownName] : genres
        })
    }

    public func groups(ofKind kind: BookGroup.Kind) -> [BookGroup] {
        switch kind {
        case .author:
            return authorGroups
        case .narrator:
            return narratorGroups
        case .genre:
            return genreGroups
        }
    }

    /// Groups of the active kind whose books match the query, keeping their
    /// headings. An empty query passes all.
    public func groups(matching query: String) -> [BookGroup] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        let all = groups(ofKind: groupKind)
        guard !trimmed.isEmpty else { return all }
        return all.compactMap { group in
            group.keeping { $0.matches(trimmed) }
        }
    }

    /// The unfiltered group with the same identity, for scoping to the
    /// full shelf after clicking a filtered subset.
    public func fullGroup(matching group: BookGroup) -> BookGroup? {
        groups(ofKind: group.kind).first { $0.id == group.id }
    }

    /// Groups of the active kind matching the query, keeping only the books
    /// that pass the active filters.
    public func visibleGroups(filters: LibraryFilters, catalog: BookCatalog) -> [BookGroup] {
        groups(matching: filters.searchQuery).compactMap { group in
            group.keeping { passesFilters($0, filters: filters, catalog: catalog) }
        }
    }

    /// One group's books matching the query, keeping only the books that
    /// pass the active filters.
    public func visibleBooks(in group: BookGroup, filters: LibraryFilters, catalog: BookCatalog) -> [Book] {
        books(in: group, matching: filters.searchQuery)
            .filter { passesFilters($0, filters: filters, catalog: catalog) }
    }

    /// True when the book passes every filter that is on.
    private func passesFilters(_ book: Book, filters: LibraryFilters, catalog: BookCatalog) -> Bool {
        (!filters.downloadedOnly || catalog.isDownloaded(book))
            && (!filters.inProgressOnly || catalog.isInProgress(book))
    }

    /// One group's books, filtered by the query when it is not empty.
    public func books(in group: BookGroup, matching query: String) -> [Book] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return group.books }
        return group.books.filter { $0.matches(trimmed) }
    }

    /// Groups books under derived names; a book with several names, such as
    /// genres, appears in each group. Books keep the server's title order
    /// within each group, and names sort ignoring a leading article, with
    /// the Unknown group last.
    private static func group(_ books: [Book], kind: BookGroup.Kind, by names: (Book) -> [String]) -> [BookGroup] {
        var grouped: [String: [Book]] = [:]
        for book in books {
            for name in names(book) {
                grouped[name, default: []].append(book)
            }
        }
        let names = grouped.keys
            .sorted { sortKey($0).localizedStandardCompare(sortKey($1)) == .orderedAscending }
        let ordered = names.filter { $0 != unknownName } + names.filter { $0 == unknownName }
        return ordered.map { BookGroup(name: $0, kind: kind, books: grouped[$0]!) }
    }

    private static func sortKey(_ name: String) -> String {
        for article in ["The ", "A ", "An "] where name.hasPrefix(article) {
            return String(name.dropFirst(article.count))
        }
        return name
    }
}
