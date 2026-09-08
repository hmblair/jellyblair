import Foundation

/// Number of Jellyfin ticks in one second.
public let ticksPerSecond: Double = 10_000_000

struct AuthResponse: Decodable {
    let accessToken: String
    let user: AuthUser

    enum CodingKeys: String, CodingKey {
        case accessToken = "AccessToken"
        case user = "User"
    }
}

struct AuthUser: Decodable {
    let id: String

    enum CodingKeys: String, CodingKey {
        case id = "Id"
    }
}

struct ItemsResponse: Decodable {
    let items: [Book]

    enum CodingKeys: String, CodingKey {
        case items = "Items"
    }
}

struct LyricsResponse: Decodable {
    let lyrics: [LyricsResponseLine]

    enum CodingKeys: String, CodingKey {
        case lyrics = "Lyrics"
    }
}

struct LyricsResponseLine: Decodable {
    let text: String
    let startTicks: Int64?
    let cues: [LyricsResponseCue]?

    enum CodingKeys: String, CodingKey {
        case text = "Text"
        case startTicks = "Start"
        case cues = "Cues"
    }
}

struct LyricsResponseCue: Decodable {
    let position: Int
    let endPosition: Int?
    let startTicks: Int64

    enum CodingKeys: String, CodingKey {
        case position = "Position"
        case endPosition = "EndPosition"
        case startTicks = "Start"
    }
}

extension LyricsResponse {
    /// The transcript lines the response describes.
    var transcriptLines: [LyricLine] {
        lyrics.enumerated().map { index, line in line.transcriptLine(at: index) }
    }
}

extension LyricsResponseLine {
    /// The transcript line the response line describes, at its place in the
    /// transcript.
    func transcriptLine(at index: Int) -> LyricLine {
        LyricLine(
            index: index,
            text: text,
            startSeconds: startTicks.map { Double($0) / ticksPerSecond },
            cues: (cues ?? []).map { $0.transcriptCue(lineLength: text.count) }
        )
    }
}

extension LyricsResponseCue {
    /// The word timing the response cue describes. A cue that reports no end
    /// position runs to the end of its line.
    func transcriptCue(lineLength: Int) -> LyricCue {
        LyricCue(
            startSeconds: Double(startTicks) / ticksPerSecond,
            startPosition: position,
            endPosition: endPosition ?? lineLength
        )
    }
}

/// Parses one of the server's timestamps.
func parseServerDate(_ text: String) -> Date? {
    serverDateFormatter.date(from: withoutFractionalSeconds(text))
}

private let serverDateFormatter: ISO8601DateFormatter = {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime]
    return formatter
}()

/// Removes a timestamp's fractional seconds, which the server writes with
/// more digits than the parser accepts.
private func withoutFractionalSeconds(_ text: String) -> String {
    guard let start = text.firstIndex(of: ".") else { return text }
    let end = text[start...].firstIndex { "Z+-".contains($0) } ?? text.endIndex
    return text.replacingCharacters(in: start..<end, with: "")
}
