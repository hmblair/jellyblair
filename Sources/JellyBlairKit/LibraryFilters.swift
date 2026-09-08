import Foundation

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
