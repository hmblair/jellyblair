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

public struct BookUserData: Codable, Hashable {
    public let playbackPositionTicks: Int64

    enum CodingKeys: String, CodingKey {
        case playbackPositionTicks = "PlaybackPositionTicks"
    }
}

public struct Person: Codable, Hashable {
    public let name: String
    public let type: String

    enum CodingKeys: String, CodingKey {
        case name = "Name"
        case type = "Type"
    }
}

public struct MediaSource: Codable, Hashable {
    public let container: String?
    public let size: Int64?
    public let bitrate: Int?

    enum CodingKeys: String, CodingKey {
        case container = "Container"
        case size = "Size"
        case bitrate = "Bitrate"
    }
}

public struct Book: Codable, Identifiable, Hashable {
    public let id: String
    public let name: String
    public let runTimeTicks: Int64?
    public let userData: BookUserData?
    public let albumArtist: String?
    public let artists: [String]?
    public let people: [Person]?
    public let mediaSources: [MediaSource]?
    public let genres: [String]?
    public let hasLyrics: Bool?

    enum CodingKeys: String, CodingKey {
        case id = "Id"
        case name = "Name"
        case runTimeTicks = "RunTimeTicks"
        case userData = "UserData"
        case albumArtist = "AlbumArtist"
        case artists = "Artists"
        case people = "People"
        case mediaSources = "MediaSources"
        case genres = "Genres"
        case hasLyrics = "HasLyrics"
    }

    /// The audio container format, for naming downloaded files.
    public var container: String? {
        mediaSources?.first?.container
    }

    /// The audio file's size in bytes, when the server reports it.
    public var fileSizeBytes: Int64? {
        mediaSources?.first?.size
    }

    /// The file's overall bitrate in kilobits per second, when the server
    /// reports it.
    public var bitrateKbps: Int? {
        guard let bitrate = mediaSources?.first?.bitrate else { return nil }
        return Int((Double(bitrate) / 1000).rounded())
    }

    public var author: String? {
        if let albumArtist, !albumArtist.isEmpty {
            return albumArtist
        }
        let joined = (artists ?? []).joined(separator: ", ")
        return joined.isEmpty ? nil : joined
    }

    /// True when the title, author, narrator, or genre contains the query.
    /// The single matcher behind every search field in the app.
    public func matches(_ query: String) -> Bool {
        name.localizedCaseInsensitiveContains(query)
            || (author?.localizedCaseInsensitiveContains(query) ?? false)
            || (narrator?.localizedCaseInsensitiveContains(query) ?? false)
            || (genre?.localizedCaseInsensitiveContains(query) ?? false)
    }

    /// The genres joined, as the single string the search matcher checks.
    public var genre: String? {
        let joined = (genres ?? []).joined(separator: ", ")
        return joined.isEmpty ? nil : joined
    }

    /// Jellyfin stores audiobook narrators as people with the Composer type.
    public var narrators: [String] {
        (people ?? []).filter { $0.type == "Composer" }.map(\.name)
    }

    /// The narrators joined, as the single string the search matcher checks.
    public var narrator: String? {
        let joined = narrators.joined(separator: ", ")
        return joined.isEmpty ? nil : joined
    }

    public var runTimeSeconds: Double {
        Double(runTimeTicks ?? 0) / ticksPerSecond
    }

    public var resumePositionSeconds: Double {
        Double(userData?.playbackPositionTicks ?? 0) / ticksPerSecond
    }
}

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
    public let endSeconds: Double
    public let startPosition: Int
    public let endPosition: Int
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

/// A chapter marker read from the audio file itself.
public struct Chapter: Identifiable, Hashable, Codable {
    public let index: Int
    public let title: String
    public let startSeconds: Double
    public let endSeconds: Double

    public var id: Int { index }

    public var durationSeconds: Double {
        max(0, endSeconds - startSeconds)
    }
}
