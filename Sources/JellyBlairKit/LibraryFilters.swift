import SwiftUI

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
        }
    }
}

/// The library list's filters and sort order, threaded whole from the filter
/// bar to the visibility functions, so a new filter touches neither
/// platform's screen.
public struct LibraryFilters: Equatable {
    public var searchQuery = ""
    public var downloadedOnly = false
    public private(set) var startedOnly = false
    public var favoritesOnly = false
    public var sortOrder = BookSortOrder.name

    public init() {}

    /// Whether at least one filter toggle is on.
    public var hasActiveFilter: Bool {
        !activeFilters.isEmpty
    }

    /// The filter toggles that are on, in the filter menu's order.
    public var activeFilters: [BookFilter] {
        BookFilter.allCases.filter { $0.isOn(in: self) }
    }

    /// Turns the started filter on or off, and puts the list in the order
    /// that suits it: the started books read most recently played first,
    /// and the whole library reads by title. The sort menu can then choose
    /// another order.
    public mutating func setStartedOnly(_ isOn: Bool) {
        startedOnly = isOn
        sortOrder = isOn ? .lastPlayed : .name
    }
}

/// One of the library's filter toggles: it reads its state from the
/// filters, tests one book, and names its books in the empty state.
public enum BookFilter: CaseIterable {
    case started
    case downloaded
    case favorites

    /// True when this filter's toggle is on.
    func isOn(in filters: LibraryFilters) -> Bool {
        switch self {
        case .started:
            return filters.startedOnly
        case .downloaded:
            return filters.downloadedOnly
        case .favorites:
            return filters.favoritesOnly
        }
    }

    /// True when the book passes this filter. The loaded book counts as
    /// started even before playback's first position write.
    @MainActor
    func passes(_ book: Book, loadedBookID: String?) -> Bool {
        switch self {
        case .started:
            return book.isStarted || book.id == loadedBookID
        case .downloaded:
            return book.isDownloaded
        case .favorites:
            return book.isFavorite
        }
    }

    /// The word this filter puts before "Books" in the empty state.
    var adjective: String {
        switch self {
        case .started:
            return String(localized: "Started")
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
