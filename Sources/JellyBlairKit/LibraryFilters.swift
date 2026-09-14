import SwiftUI

/// The direction a sort order runs in.
public enum SortDirection: Hashable {
    case ascending
    case descending

    public var flipped: SortDirection {
        self == .ascending ? .descending : .ascending
    }

    /// The direction's name in the sort menu.
    public var label: LocalizedStringKey {
        self == .ascending ? "Ascending" : "Descending"
    }

    /// The symbol beside the direction's name in the sort menu.
    public var icon: Icon {
        self == .ascending ? ascendingIcon : descendingIcon
    }
}

/// The order a list of books is shown in. The titles start at A, and the
/// durations and the remaining times at the shortest. The plays start at
/// the most recent one, and the years at the newest.
public enum BookSortOrder: CaseIterable, Hashable, Identifiable {
    case name
    case lastPlayed
    case year
    case duration
    case remaining

    public var id: Self { self }

    /// The direction the order starts in when chosen.
    public var defaultDirection: SortDirection {
        switch self {
        case .name, .duration, .remaining:
            return .ascending
        case .lastPlayed, .year:
            return .descending
        }
    }

    /// The order's name in the sort menu.
    public var label: LocalizedStringKey {
        switch self {
        case .name:
            return "Title"
        case .lastPlayed:
            return "Last Played"
        case .year:
            return "Year"
        case .duration:
            return "Duration"
        case .remaining:
            return "Time Remaining"
        }
    }

    /// The symbol beside the order's name in the sort menu.
    public var icon: Icon {
        switch self {
        case .name:
            return titleSortIcon
        case .lastPlayed:
            return lastPlayedSortIcon
        case .year:
            return yearIcon
        case .duration:
            return durationIcon
        case .remaining:
            return remainingSortIcon
        }
    }
}

/// The library list's filters and sort order, threaded whole from the filter
/// bar to the visibility functions, so a new filter touches neither
/// platform's screen.
public struct LibraryFilters: Equatable {
    public var searchQuery = ""
    public var downloadedOnly = false
    public private(set) var readingOnly = false
    public private(set) var playedFilter: PlayedFilter?
    public var favoritesOnly = false
    public private(set) var sortOrder = BookSortOrder.name
    public private(set) var sortDirection = BookSortOrder.name.defaultDirection

    public init() {}

    /// Chooses the order and starts it in its default direction.
    public mutating func setSortOrder(_ order: BookSortOrder) {
        sortOrder = order
        sortDirection = order.defaultDirection
    }

    /// Flips the current order's direction.
    public mutating func toggleSortDirection() {
        sortDirection = sortDirection.flipped
    }

    /// Whether at least one filter toggle is on.
    public var hasActiveFilter: Bool {
        !activeFilters.isEmpty
    }

    /// The filter toggles that are on, in the filter menu's order.
    public var activeFilters: [BookFilter] {
        BookFilter.allCases.filter { $0.isOn(in: self) }
    }

    /// Turns the reading filter on or off, and puts the list in the order
    /// that suits it: the books being read most recently played first, and
    /// the whole library reads by title. The sort menu can then choose
    /// another order.
    public mutating func setReadingOnly(_ isOn: Bool) {
        readingOnly = isOn
        setSortOrder(isOn ? .lastPlayed : .name)
    }

    /// Turns a played filter on, or off when it is already on. Read and
    /// Unread replace each other, since no book passes both.
    public mutating func togglePlayedFilter(_ filter: PlayedFilter) {
        playedFilter = playedFilter == filter ? nil : filter
    }
}

/// The two sides of the server's played flag: Read keeps the books the
/// server marks played, and Unread keeps the rest.
public enum PlayedFilter {
    case read
    case unread
}

/// One of the library's filter toggles: it reads its state from the
/// filters, tests one book, and names its books in the empty state.
public enum BookFilter: CaseIterable {
    case unread
    case read
    case reading
    case downloaded
    case favorites

    /// True when this filter's toggle is on.
    func isOn(in filters: LibraryFilters) -> Bool {
        switch self {
        case .reading:
            return filters.readingOnly
        case .unread:
            return filters.playedFilter == .unread
        case .read:
            return filters.playedFilter == .read
        case .downloaded:
            return filters.downloadedOnly
        case .favorites:
            return filters.favoritesOnly
        }
    }

    /// True when the book passes this filter. The loaded book counts as
    /// being read even before playback's first position write.
    @MainActor
    func passes(_ book: Book, loadedBookID: String?) -> Bool {
        switch self {
        case .reading:
            return book.isStarted || book.id == loadedBookID
        case .unread:
            return !book.isPlayed
        case .read:
            return book.isPlayed
        case .downloaded:
            return book.isDownloaded
        case .favorites:
            return book.isFavorite
        }
    }

    /// The word this filter puts before "Books" in the empty state.
    var adjective: String {
        switch self {
        case .reading:
            return String(localized: "In-Progress")
        case .unread:
            return String(localized: "Unread")
        case .read:
            return String(localized: "Read")
        case .downloaded:
            return String(localized: "Downloaded")
        case .favorites:
            return String(localized: "Favorite")
        }
    }
}

public extension [BookFilter] {
    /// The books this combination of filters keeps, as the empty state
    /// names them: each filter's adjective in menu order, before "Books".
    var booksName: String {
        (map(\.adjective) + [String(localized: "Books")]).joined(separator: " ")
    }
}
