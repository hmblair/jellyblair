import Foundation

/// Number of Jellyfin ticks in one second.
public let ticksPerSecond: Double = 10_000_000

struct AuthResponse: Decodable {
    let accessToken: String

    enum CodingKeys: String, CodingKey {
        case accessToken = "AccessToken"
    }
}

struct PublicSystemInfo: Decodable {
    let version: String?

    enum CodingKeys: String, CodingKey {
        case version = "Version"
    }
}

struct ItemsResponse<Item: Decodable>: Decodable {
    let items: [Item]

    enum CodingKeys: String, CodingKey {
        case items = "Items"
    }
}

/// One audiobook item of a response: the book's record, and the identifier
/// of the folder that holds the book.
struct BookItem: Decodable {
    let record: BookRecord
    let parentID: String?

    enum CodingKeys: String, CodingKey {
        case parentID = "ParentId"
    }

    init(from decoder: Decoder) throws {
        record = try BookRecord(from: decoder)
        parentID = try decoder.container(keyedBy: CodingKeys.self).decodeIfPresent(String.self, forKey: .parentID)
    }
}

struct FolderRecord: Decodable {
    let id: String
    let name: String
    let type: String

    enum CodingKeys: String, CodingKey {
        case id = "Id"
        case name = "Name"
        case type = "Type"
    }

    /// The type of a folder inside a library. A library carries another
    /// type.
    private static let plainFolderType = "Folder"

    var isPlainFolder: Bool {
        type == Self.plainFolderType
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
    let endTicks: Int64?

    enum CodingKeys: String, CodingKey {
        case position = "Position"
        case endPosition = "EndPosition"
        case startTicks = "Start"
        case endTicks = "End"
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
            endSeconds: endTicks.map { Double($0) / ticksPerSecond },
            startPosition: position,
            endPosition: endPosition ?? lineLength
        )
    }
}

/// Parses one of the server's timestamps.
func parseServerDate(_ text: String) -> Date? {
    serverDateFormatter.date(from: withoutFractionalSeconds(text))
}

/// The year of a date as the server writes it, which is the year in UTC.
func serverYear(of date: Date) -> Int {
    serverCalendar.component(.year, from: date)
}

/// The time zone the server writes its dates in.
let serverTimeZone = TimeZone.gmt

private let serverCalendar: Calendar = {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = serverTimeZone
    return calendar
}()

/// Writes a timestamp in the server's format.
func formatServerDate(_ date: Date) -> String {
    serverDateFormatter.string(from: date)
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
