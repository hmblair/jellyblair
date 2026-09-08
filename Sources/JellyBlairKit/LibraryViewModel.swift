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

/// The symbol for a book's length, shared by the book screen's metadata
/// lines and the sort menu.
public let durationIconName = "clock.fill"

/// The symbol for a book's year, shared by the book screen's metadata lines
/// and the sort menu.
public let yearIconName = "calendar"

/// The order a list of books is shown in. The titles start at A and the
/// durations at the shortest book. The plays start at the most recent one,
/// and the years at the newest.
public enum BookSortOrder: CaseIterable, Hashable, Identifiable {
    case name
    case lastPlayed
    case year
    case duration

    public var id: Self { self }

    /// The order's name in the sort menu.
    public var label: String {
        switch self {
        case .name:
            return "Title"
        case .lastPlayed:
            return "Last Played"
        case .year:
            return "Year"
        case .duration:
            return "Duration"
        }
    }

    /// The symbol beside the order's name in the sort menu.
    public var iconName: String {
        switch self {
        case .name:
            return "textformat"
        case .lastPlayed:
            return "clock.arrow.circlepath"
        case .year:
            return yearIconName
        case .duration:
            return durationIconName
        }
    }
}

/// The library list's filters and sort order, threaded whole from the filter
/// bar to the visibility functions, so a new filter touches neither
/// platform's screen.
public struct LibraryFilters: Equatable {
    public var searchQuery = ""
    public var downloadedOnly = false
    public private(set) var inProgressOnly = false
    public var sortOrder = BookSortOrder.name

    public init() {}

    /// Turns the in-progress filter on or off, and puts the list in the
    /// order that suits it: the books in progress read most recently played
    /// first, and the whole library reads by title. The sort menu can then
    /// choose another order.
    public mutating func setInProgressOnly(_ isOn: Bool) {
        inProgressOnly = isOn
        sortOrder = isOn ? .lastPlayed : .name
    }
}

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

    /// All books in the filters' sort order, matching the query and passing
    /// the active filters.
    public func visibleBooks(filters: LibraryFilters, catalog: BookCatalog, loadedBookID: String?) -> [Book] {
        books(inOrder: filters.sortOrder).filter { book in
            (filters.searchQuery.isEmpty || book.matches(filters.searchQuery))
                && passesFilters(book, filters: filters, catalog: catalog, loadedBookID: loadedBookID)
        }
    }

    /// One group's books matching the query, keeping only the books that
    /// pass the active filters, in the filters' sort order.
    public func visibleBooks(in group: BookGroup, filters: LibraryFilters, catalog: BookCatalog, loadedBookID: String?) -> [Book] {
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
