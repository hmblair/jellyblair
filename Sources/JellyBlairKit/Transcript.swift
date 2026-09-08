import Foundation

/// One line of a book's transcript, read from the lyric sidecar on the server.
public struct LyricLine: Identifiable, Hashable, Codable {
    public let index: Int
    public let text: String
    /// When the line is spoken, or nil when the sidecar has no timestamps.
    public let startSeconds: Double?
    /// Word timings within the line, when the sidecar carries them.
    public let cues: [LyricCue]

    public var id: Int { index }
}

/// One word's timing within a transcript line: when it is spoken, and the
/// character range it covers in the line's text.
public struct LyricCue: Hashable, Codable {
    public let startSeconds: Double
    public let startPosition: Int
    public let endPosition: Int
}
