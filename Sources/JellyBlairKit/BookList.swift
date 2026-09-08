import Foundation

/// A named shelf of books: one author's, one narrator's, or one genre's.
public struct BookGroup: Identifiable, Hashable {
    public enum Kind: Hashable {
        case author
        case narrator
        case genre

        /// The symbol for this role.
        public var iconName: String {
            switch self {
            case .author:
                return authorIconName
            case .narrator:
                return narratorIconName
            case .genre:
                return genreIconName
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
    public let iconName: String
}
