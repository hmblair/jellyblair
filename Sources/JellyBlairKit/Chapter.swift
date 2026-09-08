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

    public var durationSeconds: Double {
        max(0, endSeconds - startSeconds)
    }
}
