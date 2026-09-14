import Foundation

/// A title divided at its first colon, so a screen can show the parts
/// differently. A title with no colon has no subtitle.
public struct SplitTitle: Hashable {
    public let main: String
    public let subtitle: String?
}

/// Splits a title at the first colon that whitespace follows, so a colon
/// inside a time or a ratio keeps the title whole. An empty part on either
/// side also keeps it whole.
public func splitTitle(_ title: String) -> SplitTitle {
    guard let colon = firstSeparatingColon(in: title) else {
        return SplitTitle(main: title, subtitle: nil)
    }
    let main = trimmed(title[title.startIndex..<colon])
    let subtitle = trimmed(title[title.index(after: colon)...])
    guard !main.isEmpty, !subtitle.isEmpty else {
        return SplitTitle(main: title, subtitle: nil)
    }
    return SplitTitle(main: main, subtitle: subtitle)
}

/// The index of the first colon that whitespace follows.
private func firstSeparatingColon(in title: String) -> String.Index? {
    var index = title.startIndex
    while let colon = title[index...].firstIndex(of: ":") {
        let next = title.index(after: colon)
        if next < title.endIndex, title[next].isWhitespace {
            return colon
        }
        guard next < title.endIndex else { return nil }
        index = next
    }
    return nil
}

private func trimmed(_ part: Substring) -> String {
    part.trimmingCharacters(in: .whitespaces)
}
