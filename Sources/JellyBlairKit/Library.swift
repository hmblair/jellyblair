import Foundation
import Observation

/// The list of books. Fetches the server's records, creates the one Book
/// object per record, keeps the books in each sort order, persists the
/// snapshot and the chapter lists, and bounds how many parsed stream assets
/// stay in memory.
@MainActor
@Observable
public final class Library {
    public let client: JellyfinClient

    public private(set) var books: [Book] = []
    /// The books in each sort order, each exactly once, so the flat library
    /// list sorts when the books change rather than on every view pass.
    private var sortedBooks: [BookSortOrder: [Book]] = [:]

    public private(set) var isLoading = true
    public private(set) var errorMessage: String?

    private let recordStore = LibraryStore()
    @ObservationIgnored private var chapterCache: [String: [Chapter]]
    private let chapterStore = ChapterStore()

    /// The books holding a parsed stream asset, most recently parsed first.
    /// Assets beyond the cap release, since each can hold megabytes of
    /// index data.
    @ObservationIgnored private var booksHoldingAssets: [Book] = []
    private static let retainedAssetCount = 3

    public init(client: JellyfinClient) {
        self.client = client
        chapterCache = chapterStore.load()
        // The last snapshot shows immediately and carries offline launches.
        // The file is the source here, so nothing writes back to it.
        let cached = recordStore.load().map { makeBook(for: $0) }
        books = cached
        sortedBooks = Self.sortedInEveryOrder(cached)
    }

    public func load() async {
        isLoading = true
        errorMessage = nil
        do {
            let fetched = try await client.fetchAudiobooks()
            adoptRecords(fetched)
        } catch {
            // The cached snapshot stands; the overlay only shows the error
            // when there are no books at all.
            Log.network.warning("The library refresh failed: \(error.localizedDescription, privacy: .public)")
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }

    // MARK: - Books

    /// Creates the one Book for a record, hooked to the library: chapter
    /// lists persist, record changes reach the file and the sort orders,
    /// and parsed assets stay bounded.
    private func makeBook(for record: BookRecord) -> Book {
        let book = Book(
            record: record,
            client: client,
            initialChapters: chapterCache[record.id] ?? []
        ) { [weak self] chapters in
            self?.storeChapters(chapters, for: record.id)
        }
        book.onRecordChanged = { [weak self] in
            self?.handleRecordChange()
        }
        book.onAssetParsed = { [weak self] book in
            self?.noteAssetParse(of: book)
        }
        return book
    }

    /// Adopts a fresh record list: known books take their new records, new
    /// books join, and dropped books leave. An unchanged list writes
    /// nothing, so a no-op refresh invalidates no observers and leaves the
    /// file alone.
    private func adoptRecords(_ records: [BookRecord]) {
        let known = Dictionary(books.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var recordsChanged = false
        let fresh = records.map { record -> Book in
            guard let book = known[record.id] else {
                recordsChanged = true
                return makeBook(for: record)
            }
            recordsChanged = book.adoptRecord(record) || recordsChanged
            return book
        }
        guard recordsChanged || fresh.map(\.id) != books.map(\.id) else { return }
        setBooks(fresh)
    }

    /// The one writer of the book list after initialization. The sort
    /// orders and the snapshot file rebuild with it, so they always hold
    /// the same books.
    private func setBooks(_ newBooks: [Book]) {
        books = newBooks
        sortedBooks = Self.sortedInEveryOrder(newBooks)
        recordStore.save(newBooks.map(\.record))
    }

    /// A changed record can move its book in the sort orders and must
    /// reach the snapshot file.
    private func handleRecordChange() {
        resortBooks()
        recordStore.save(books.map(\.record))
    }

    /// Rebuilds the sort orders. Unchanged orders stand, so a position
    /// write, which no order reads, invalidates no list observers.
    private func resortBooks() {
        let fresh = Self.sortedInEveryOrder(books)
        guard fresh.mapValues({ $0.map(\.id) }) != sortedBooks.mapValues({ $0.map(\.id) }) else { return }
        sortedBooks = fresh
    }

    /// The book carrying the identifier, or nil once a refresh has dropped
    /// it from the library.
    public func book(withID id: String?) -> Book? {
        guard let id else { return nil }
        return books.first { $0.id == id }
    }

    // MARK: - Chapter persistence

    private func storeChapters(_ chapters: [Chapter], for bookID: String) {
        if chapters.isEmpty {
            chapterCache.removeValue(forKey: bookID)
        } else {
            chapterCache[bookID] = chapters
        }
        chapterStore.save(chapterCache)
    }

    // MARK: - Asset bounding

    /// Moves the book to the front of the asset holders and releases the
    /// assets beyond the cap.
    private func noteAssetParse(of book: Book) {
        booksHoldingAssets.removeAll { $0 === book }
        booksHoldingAssets.insert(book, at: 0)
        for stale in booksHoldingAssets.dropFirst(Self.retainedAssetCount) {
            stale.releaseAsset()
        }
        booksHoldingAssets = Array(booksHoldingAssets.prefix(Self.retainedAssetCount))
    }

    // MARK: - Groups

    /// The named group of one kind, built on demand from the book list, or
    /// nil when no book carries the name. Books keep the server's title order.
    public func group(ofKind kind: BookGroup.Kind, named name: String) -> BookGroup? {
        let matching = books.filter { kind.names(of: $0).contains(name) }
        guard !matching.isEmpty else { return nil }
        return BookGroup(name: name, kind: kind, books: matching)
    }

    /// One group's books, filtered by the query when it is not empty.
    public func books(in group: BookGroup, matching query: String) -> [Book] {
        guard !query.isEmpty else { return group.books }
        return group.books.filter { $0.matches(query) }
    }

    // MARK: - Visible lists

    /// The list to show: one group's books under the group's heading when a
    /// group is given, and the whole library's books without a heading
    /// otherwise. Both match the query, pass the active filters, and read in
    /// the filters' sort order.
    public func visibleList(in group: BookGroup?, filters: LibraryFilters, loadedBookID: String?) -> BookList {
        guard let group else {
            return BookList(
                heading: nil,
                books: visibleBooksInLibrary(filters: filters, loadedBookID: loadedBookID)
            )
        }
        return BookList(
            heading: BookListHeading(name: group.name, icon: group.icon),
            books: visibleBooks(in: group, filters: filters, loadedBookID: loadedBookID)
        )
    }

    /// All books in the filters' sort order, matching the query and passing
    /// the active filters.
    private func visibleBooksInLibrary(filters: LibraryFilters, loadedBookID: String?) -> [Book] {
        books(inOrder: filters.sortOrder).filter { book in
            (filters.searchQuery.isEmpty || book.matches(filters.searchQuery))
                && passesFilters(book, filters: filters, loadedBookID: loadedBookID)
        }
    }

    /// One group's books matching the query, keeping only the books that
    /// pass the active filters, in the filters' sort order.
    private func visibleBooks(in group: BookGroup, filters: LibraryFilters, loadedBookID: String?) -> [Book] {
        let matching = books(in: group, matching: filters.searchQuery)
            .filter { passesFilters($0, filters: filters, loadedBookID: loadedBookID) }
        return Self.sorted(matching, by: filters.sortOrder)
    }

    /// True when the book passes every filter that is on.
    private func passesFilters(_ book: Book, filters: LibraryFilters, loadedBookID: String?) -> Bool {
        filters.activeFilters.allSatisfy { $0.passes(book, loadedBookID: loadedBookID) }
    }

    // MARK: - Empty lists

    /// The empty state's title when no book passes the search and filters.
    /// It names the filters that keep no book of the scope at all, or the
    /// active combination when each filter keeps books on its own, or a
    /// missing search match when the filters alone leave books.
    public func emptyListTitle(in group: BookGroup?, filters: LibraryFilters, loadedBookID: String?) -> String {
        let scope = group?.books ?? books
        let active = filters.activeFilters
        guard booksPassingFilters(in: scope, active: active, loadedBookID: loadedBookID).isEmpty else {
            return "No Matching \(active.booksName)"
        }
        let emptyFilters = filtersKeepingNoBook(in: scope, active: active, loadedBookID: loadedBookID)
        guard !emptyFilters.isEmpty else { return "No \(active.booksName)" }
        return "No " + emptyFilters.map { [$0].booksName }.joined(separator: " or ")
    }

    /// The scope's books passing the active filters, ignoring the search.
    private func booksPassingFilters(in scope: [Book], active: [BookFilter], loadedBookID: String?) -> [Book] {
        scope.filter { book in active.allSatisfy { $0.passes(book, loadedBookID: loadedBookID) } }
    }

    /// The active filters that no book of the scope passes on its own.
    private func filtersKeepingNoBook(in scope: [Book], active: [BookFilter], loadedBookID: String?) -> [BookFilter] {
        active.filter { filter in !scope.contains { filter.passes($0, loadedBookID: loadedBookID) } }
    }

    // MARK: - Sorting

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
            return sortedLargestFirst(books) { $0.record.lastPlayedDate }
        case .year:
            return sortedLargestFirst(books) { $0.record.productionYear }
        case .duration:
            return sortedSmallestFirst(books) { $0.record.runTimeTicks }
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

    /// The name without a leading article, for sorting.
    private static func sortKey(_ name: String) -> String {
        for article in ["The ", "A ", "An "] where name.hasPrefix(article) {
            return String(name.dropFirst(article.count))
        }
        return name
    }
}
