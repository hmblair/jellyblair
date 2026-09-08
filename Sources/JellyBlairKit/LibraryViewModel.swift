import Foundation
import Observation

/// Holds the audiobook list in each order the library list can show, and
/// builds one author's, narrator's, or genre's group on demand for the
/// scoped screens.
@MainActor
@Observable
public final class LibraryViewModel {
    public let client: JellyfinClient

    public private(set) var books: [Book] = []
    /// The books in each sort order, each exactly once, so the flat library
    /// list sorts when the books change rather than on every view pass.
    private var sortedBooks: [BookSortOrder: [Book]] = [:]

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
        sortedBooks = Self.sortedInEveryOrder(cached)
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
        setBooks(newBooks, sortedAs: Self.sortedInEveryOrder(newBooks))
    }

    /// Puts a book at its index in the main list and in place of its ID in
    /// every sorted list. The resume position is the only field that changes
    /// here, and no order reads it, so no list moves and none needs a sort.
    private func replace(_ book: Book, at index: Int) {
        var updated = books
        updated[index] = book
        var sorted = sortedBooks
        for (order, list) in sorted {
            guard let sortedIndex = list.firstIndex(where: { $0.id == book.id }) else { continue }
            sorted[order]?[sortedIndex] = book
        }
        setBooks(updated, sortedAs: sorted)
    }

    /// The one writer of the lists and the cached file after initialization,
    /// so they always hold the same books. Callers build every order; the
    /// caller's arrays are written, never the freshly set property. Reading
    /// an observable back inside its own update runs observation tracking
    /// mid-change, which can crash in the runtime's access list.
    private func setBooks(_ newBooks: [Book], sortedAs newSortedBooks: [BookSortOrder: [Book]]) {
        books = newBooks
        sortedBooks = newSortedBooks
        store.save(newBooks)
    }

    /// The books in each order the library list can show.
    public func books(inOrder order: BookSortOrder) -> [Book] {
        sortedBooks[order] ?? []
    }

    /// Sorts a list once for every order.
    private static func sortedInEveryOrder(_ books: [Book]) -> [BookSortOrder: [Book]] {
        Dictionary(uniqueKeysWithValues: BookSortOrder.allCases.map { ($0, sorted(books, by: $0)) })
    }

    /// Sorts a list in one order.
    private static func sorted(_ books: [Book], by order: BookSortOrder) -> [Book] {
        switch order {
        case .name:
            return sortedByName(books)
        case .lastPlayed:
            return sortedLargestFirst(books) { $0.lastPlayedDate }
        case .year:
            return sortedLargestFirst(books) { $0.productionYear }
        case .duration:
            return sortedSmallestFirst(books) { $0.runTimeTicks }
        }
    }

    /// Sorts a list by name.
    private static func sortedByName(_ books: [Book]) -> [Book] {
        books.sorted { comesFirstByName($0, $1) }
    }

    /// Sorts a list by one of the books' values, largest first.
    private static func sortedLargestFirst<Value: Comparable>(_ books: [Book], by value: (Book) -> Value?) -> [Book] {
        sortedByValue(books, by: value) { $0 > $1 }
    }

    /// Sorts a list by one of the books' values, smallest first.
    private static func sortedSmallestFirst<Value: Comparable>(_ books: [Book], by value: (Book) -> Value?) -> [Book] {
        sortedByValue(books, by: value) { $0 < $1 }
    }

    /// Sorts a list by one of the books' values, in the order the comparison
    /// gives. A book the server reports no value for comes after every book
    /// that has one, and books with equal values read by name.
    private static func sortedByValue<Value: Comparable>(
        _ books: [Book],
        by value: (Book) -> Value?,
        comesFirst: (Value, Value) -> Bool
    ) -> [Book] {
        books.sorted { left, right in
            let leftValue = value(left)
            let rightValue = value(right)
            guard leftValue != rightValue else { return comesFirstByName(left, right) }
            guard let leftValue else { return false }
            guard let rightValue else { return true }
            return comesFirst(leftValue, rightValue)
        }
    }

    /// True when the first book's name sorts before the second's.
    private static func comesFirstByName(_ left: Book, _ right: Book) -> Bool {
        sortKey(left.name).localizedStandardCompare(sortKey(right.name)) == .orderedAscending
    }

    /// The book carrying the identifier, or nil once a refresh has dropped
    /// it from the library.
    public func book(withID id: String?) -> Book? {
        guard let id else { return nil }
        return books.first { $0.id == id }
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

    /// The list to show: one group's books under the group's heading when a
    /// group is given, and the whole library's books without a heading
    /// otherwise. Both match the query, pass the active filters, and read in
    /// the filters' sort order.
    public func visibleList(in group: BookGroup?, filters: LibraryFilters, catalog: BookCatalog, loadedBookID: String?) -> BookList {
        guard let group else {
            return BookList(
                heading: nil,
                books: visibleBooksInLibrary(filters: filters, catalog: catalog, loadedBookID: loadedBookID)
            )
        }
        return BookList(
            heading: BookListHeading(name: group.name, iconName: group.iconName),
            books: visibleBooks(in: group, filters: filters, catalog: catalog, loadedBookID: loadedBookID)
        )
    }

    /// All books in the filters' sort order, matching the query and passing
    /// the active filters.
    private func visibleBooksInLibrary(filters: LibraryFilters, catalog: BookCatalog, loadedBookID: String?) -> [Book] {
        books(inOrder: filters.sortOrder).filter { book in
            (filters.searchQuery.isEmpty || book.matches(filters.searchQuery))
                && passesFilters(book, filters: filters, catalog: catalog, loadedBookID: loadedBookID)
        }
    }

    /// One group's books matching the query, keeping only the books that
    /// pass the active filters, in the filters' sort order.
    private func visibleBooks(in group: BookGroup, filters: LibraryFilters, catalog: BookCatalog, loadedBookID: String?) -> [Book] {
        let matching = books(in: group, matching: filters.searchQuery)
            .filter { passesFilters($0, filters: filters, catalog: catalog, loadedBookID: loadedBookID) }
        return Self.sorted(matching, by: filters.sortOrder)
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
