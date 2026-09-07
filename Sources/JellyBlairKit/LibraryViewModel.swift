import Foundation
import Observation

/// A named shelf of books: one author's, one narrator's, or one genre's.
public struct BookGroup: Identifiable, Hashable {
    public enum Kind: Hashable {
        case author
        case narrator
        case genre

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
}

/// The library list's filters, threaded whole from the filter bar to the
/// visibility functions, so a new filter touches neither platform's screen.
public struct LibraryFilters: Equatable {
    public var searchQuery = ""
    public var downloadedOnly = false
    public var inProgressOnly = false

    public init() {}
}

/// Holds the audiobook list, sorted by name for the library list, and
/// builds one author's, narrator's, or genre's group on demand for the
/// scoped screens.
@MainActor
@Observable
public final class LibraryViewModel {
    public let client: JellyfinClient

    public private(set) var books: [Book] = []
    /// The books sorted by name, each exactly once, for the flat library list.
    public private(set) var booksByName: [Book] = []

    public private(set) var isLoading = true
    public private(set) var errorMessage: String?

    /// Called after a successful load with the fresh snapshots, so the
    /// session can sync them into state the view model does not know about.
    @ObservationIgnored public var onBooksRefreshed: (([Book]) -> Void)?

    private let store = LibraryStore()

    public init(client: JellyfinClient) {
        self.client = client
        // The last snapshot shows immediately and carries offline launches.
        // The file is the source here, so the lists start equal to it and
        // setBooks has nothing to write back.
        let cached = store.load()
        books = cached
        booksByName = Self.sortedByName(cached)
    }

    public func load() async {
        isLoading = true
        errorMessage = nil
        do {
            let fetched = try await client.fetchAudiobooks()
            applySnapshot(fetched)
            onBooksRefreshed?(fetched)
        } catch {
            // The cached snapshot stands; the overlay only shows the error
            // when there are no books at all.
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }

    /// Writes a book's position into the cached snapshot. A launch that
    /// cannot reach the server then resumes where playback stopped, not
    /// where the last fetch left the book. An unchanged position writes
    /// nothing.
    public func recordPosition(_ seconds: Double, for bookID: String) {
        guard let index = books.firstIndex(where: { $0.id == bookID }) else { return }
        // The books compare equal exactly when their stored ticks match, so
        // the guard is immune to the lossy seconds-to-ticks conversion.
        let updated = books[index].withResumePosition(seconds)
        guard updated != books[index] else { return }
        replace(updated, at: index)
    }

    /// Adopts a fresh list from the server. An unchanged list writes
    /// nothing, so a no-op refresh invalidates no observers and leaves the
    /// file alone.
    private func applySnapshot(_ newBooks: [Book]) {
        guard newBooks != books else { return }
        setBooks(newBooks, inNameOrder: Self.sortedByName(newBooks))
    }

    /// Puts a book at its index in the main list and in place of its ID in
    /// the name order. The position is the only field that changes here, so
    /// neither order moves and neither needs a sort.
    private func replace(_ book: Book, at index: Int) {
        var updated = books
        updated[index] = book
        var sorted = booksByName
        if let sortedIndex = sorted.firstIndex(where: { $0.id == book.id }) {
            sorted[sortedIndex] = book
        }
        setBooks(updated, inNameOrder: sorted)
    }

    /// The one writer of the two lists and the cached file after
    /// initialization, so the three always hold the same books. Callers
    /// build both orders; the caller's arrays are written, never the
    /// freshly set property. Reading an observable back inside its own
    /// update runs observation tracking mid-change, which can crash in the
    /// runtime's access list.
    private func setBooks(_ newBooks: [Book], inNameOrder sortedBooks: [Book]) {
        books = newBooks
        booksByName = sortedBooks
        store.save(newBooks)
    }

    /// Sorts a list by name, the order the flat library list shows.
    private static func sortedByName(_ books: [Book]) -> [Book] {
        books.sorted {
            sortKey($0.name).localizedStandardCompare(sortKey($1.name)) == .orderedAscending
        }
    }

    /// The named group of one kind, built on demand from the book list, or
    /// nil when no book carries the name. Books keep the server's title order.
    public func group(ofKind kind: BookGroup.Kind, named name: String) -> BookGroup? {
        let matching = books.filter { Self.names(of: $0, for: kind).contains(name) }
        guard !matching.isEmpty else { return nil }
        return BookGroup(name: name, kind: kind, books: matching)
    }

    /// The book's names for one grouping kind: its authors, narrators, or
    /// genres.
    private static func names(of book: Book, for kind: BookGroup.Kind) -> [String] {
        switch kind {
        case .author:
            return book.authors
        case .narrator:
            return book.narrators
        case .genre:
            return book.genres ?? []
        }
    }

    /// All books sorted by name, matching the query and passing the active
    /// filters.
    public func visibleBooks(filters: LibraryFilters, catalog: BookCatalog, loadedBookID: String?) -> [Book] {
        booksByName.filter { book in
            (filters.searchQuery.isEmpty || book.matches(filters.searchQuery))
                && passesFilters(book, filters: filters, catalog: catalog, loadedBookID: loadedBookID)
        }
    }

    /// One group's books matching the query, keeping only the books that
    /// pass the active filters.
    public func visibleBooks(in group: BookGroup, filters: LibraryFilters, catalog: BookCatalog, loadedBookID: String?) -> [Book] {
        books(in: group, matching: filters.searchQuery)
            .filter { passesFilters($0, filters: filters, catalog: catalog, loadedBookID: loadedBookID) }
    }

    /// True when the book passes every filter that is on. The loaded book
    /// counts as in progress: its live position is in the player, so the
    /// model's value stands still while it plays.
    private func passesFilters(_ book: Book, filters: LibraryFilters, catalog: BookCatalog, loadedBookID: String?) -> Bool {
        (!filters.downloadedOnly || catalog.isDownloaded(book))
            && (!filters.inProgressOnly || catalog.isInProgress(book) || book.id == loadedBookID)
    }

    /// One group's books, filtered by the query when it is not empty.
    public func books(in group: BookGroup, matching query: String) -> [Book] {
        guard !query.isEmpty else { return group.books }
        return group.books.filter { $0.matches(query) }
    }

    /// The name without a leading article, for sorting.
    private static func sortKey(_ name: String) -> String {
        for article in ["The ", "A ", "An "] where name.hasPrefix(article) {
            return String(name.dropFirst(article.count))
        }
        return name
    }
}
