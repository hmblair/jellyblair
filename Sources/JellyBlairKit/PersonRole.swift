import Foundation

/// One role a person can hold on a book, in display order. Every place
/// that spans the roles — the credit lines, the person shelf and its
/// sections, the search — iterates allCases, so a new role needs only a
/// case, its participle, and its names in the record.
public enum PersonRole: CaseIterable, Comparable {
    case author
    case translator
    case narrator

    /// The role's participle, lowercase, for the credit and section
    /// phrases.
    var participle: String {
        switch self {
        case .author:
            return String(localized: "written")
        case .translator:
            return String(localized: "translated")
        case .narrator:
            return String(localized: "read")
        }
    }
}

/// One credit line's making: the roles that share one list of names.
public struct PersonCredit: Hashable {
    public let roles: [PersonRole]
    public let names: [String]
}

public extension [PersonRole] {
    /// The credit line prefix, from "Written by" through "Written,
    /// translated, and read by".
    var creditPrefix: String {
        capitalizedFirst(joinedAsProse(map(\.participle))) + " " + String(localized: "by")
    }

    /// The section title, from "Written" through "Written, Translated,
    /// and Read".
    var sectionTitle: String {
        joinedAsProse(map { capitalizedFirst($0.participle) })
    }
}

/// Joins words as prose: "x", "x and y", or "x, y, and z".
private func joinedAsProse(_ words: [String]) -> String {
    let and = String(localized: "and")
    switch words.count {
    case 0, 1:
        return words.first ?? ""
    case 2:
        return "\(words[0]) \(and) \(words[1])"
    default:
        return words.dropLast().joined(separator: ", ") + ", \(and) \(words[words.count - 1])"
    }
}

/// Uppercases the first letter, leaving the rest as given.
private func capitalizedFirst(_ text: String) -> String {
    text.prefix(1).uppercased() + text.dropFirst()
}
