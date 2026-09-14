import Foundation

/// A chapter marker read from the audio file itself.
public struct Chapter: Identifiable, Hashable, Codable {
    /// Tolerance around a chapter's start: a position this close before the
    /// start counts as inside the chapter.
    public static let startSlackSeconds: Double = 0.5

    public let index: Int
    public let title: String
    public let startSeconds: Double
    public let endSeconds: Double

    public var id: Int { index }

    /// The title up to its first colon, or the whole title when it has
    /// none. The chapter list and the book screen show the whole title.
    public var mainTitle: String { splitTitle(title).main }

    /// The title after its first colon, when it has one.
    public var subtitle: String? { splitTitle(title).subtitle }

    public var durationSeconds: Double {
        max(0, endSeconds - startSeconds)
    }
}
