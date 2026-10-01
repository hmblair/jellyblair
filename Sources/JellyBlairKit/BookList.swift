import Foundation

/// A named shelf of books: the books of one person, one series, one
/// publisher, or one genre.
public struct BookGroup: Identifiable {
    public enum Kind: Hashable {
        case person
        case series
        case publisher
        case genre

        /// The role's name, on the group heading's detail line.
        public var label: String {
            switch self {
            case .person:
                return String(localized: "Person")
            case .series:
                return String(localized: "Series")
            case .publisher:
                return String(localized: "Publisher")
            case .genre:
                return String(localized: "Genre")
            }
        }

        /// The sort that suits the kind's shelf, or nil when the kind has
        /// none. A series reads from its oldest book to its newest.
        public var suitedSort: BookSort? {
            switch self {
            case .series:
                return BookSort(.year, direction: .ascending)
            case .person, .publisher, .genre:
                return nil
            }
        }

        /// The book's names for this grouping kind. A person's names span
        /// every role, so one shelf collects everything a name wrote,
        /// translated, and read; the shelf's sections then split the roles
        /// apart.
        @MainActor
        public func names(of book: Book) -> [String] {
            switch self {
            case .person:
                return uniqueNames(PersonRole.allCases.flatMap { book.names(for: $0) })
            case .series:
                return book.series.map { [$0] } ?? []
            case .publisher:
                return book.publishers
            case .genre:
                return book.genres
            }
        }
    }

    public let name: String
    public let kind: Kind
    public let books: [Book]

    public var id: String { "\(kind):\(name)" }
}

/// The names with duplicates removed, keeping first appearances.
private func uniqueNames(_ names: [String]) -> [String] {
    var seen = Set<String>()
    return names.filter { seen.insert($0).inserted }
}

/// A library list ready to show: the books in their sections, and the
/// heading above them when the list is one group's rather than the whole
/// library's.
public struct BookList {
    public let heading: BookListHeading?
    public let sections: [BookListSection]

    /// All visible books, across the sections.
    public var books: [Book] {
        sections.flatMap(\.books)
    }

    /// True when the list has something to show, counting a heading. A
    /// scoped list keeps its heading when no book passes the filters, so it
    /// never reads as empty.
    public var hasVisibleContent: Bool {
        heading != nil || !books.isEmpty
    }
}

/// One run of books in a list, under its own title when the list splits
/// into roles.
public struct BookListSection: Identifiable {
    /// The title over the section's books, or nil for a list that needs
    /// none.
    public let title: String?
    public let books: [Book]

    public var id: String { title ?? "" }
}

/// The text above a scoped list, with the quiet line beneath the name.
public struct BookListHeading {
    public let name: String
    /// The line under the name: the group's kind, book count, and total
    /// length.
    public let detail: String
}
