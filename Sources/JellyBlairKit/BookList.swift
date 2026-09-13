import Foundation

/// A named shelf of books: one author's, one narrator's, one publisher's,
/// or one genre's.
public struct BookGroup: Identifiable {
    public enum Kind: Hashable {
        case author
        case narrator
        case publisher
        case genre

        /// The symbol for this role.
        public var icon: Icon {
            switch self {
            case .author:
                return authorIcon
            case .narrator:
                return narratorIcon
            case .publisher:
                return publisherIcon
            case .genre:
                return genreIcon
            }
        }

        /// The book's names for this grouping kind.
        @MainActor
        public func names(of book: Book) -> [String] {
            switch self {
            case .author:
                return book.authors
            case .narrator:
                return book.narrators
            case .publisher:
                return book.publishers
            case .genre:
                return book.genres
            }
        }
    }

    /// The symbol for the group's role.
    public var icon: Icon { kind.icon }

    public let name: String
    public let kind: Kind
    public let books: [Book]

    public var id: String { "\(kind):\(name)" }
}

/// A library list ready to show: the books, and the heading above them when
/// the list is one group's rather than the whole library's.
public struct BookList {
    public let heading: BookListHeading?
    public let books: [Book]

    /// True when the list has something to show, counting a heading. A
    /// scoped list keeps its heading when no book passes the filters, so it
    /// never reads as empty.
    public var hasVisibleContent: Bool {
        heading != nil || !books.isEmpty
    }
}

/// The text and symbol above a scoped list.
public struct BookListHeading {
    public let name: String
    public let icon: Icon
}
