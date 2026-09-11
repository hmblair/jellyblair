import Foundation

/// One audiobook, as the server describes it.
public struct Book: Codable, Identifiable, Hashable {
    public let id: String
    public let name: String
    public let runTimeTicks: Int64?
    public var userData: BookUserData?
    public let albumArtist: String?
    public let artists: [String]?
    public let people: [Person]?
    public let mediaSources: [MediaSource]?
    public let genres: [String]?
    public let studios: [Studio]?
    public let hasLyrics: Bool?
    /// The year of the audiobook edition, from the file's year tag.
    public let productionYear: Int?

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
        case studios = "Studios"
        case hasLyrics = "HasLyrics"
        case productionYear = "ProductionYear"
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

    /// The individual author names: the artists list, or the album artist
    /// alone when the list is empty.
    public var authors: [String] {
        if let artists, !artists.isEmpty {
            return artists
        }
        if let albumArtist, !albumArtist.isEmpty {
            return [albumArtist]
        }
        return []
    }

    /// The authors joined, as the single string the search matcher checks.
    public var author: String? {
        let joined = authors.joined(separator: ", ")
        return joined.isEmpty ? nil : joined
    }

    /// True when the title, author, narrator, genre, or publisher contains
    /// the query, by the same matching the book screen's searches use.
    public func matches(_ query: String) -> Bool {
        [name, author, narrator, genre, publisher]
            .compactMap { $0 }
            .contains { !findOccurrences(of: query, in: $0 as NSString, caseSensitive: false, limit: 1).isEmpty }
    }

    /// The genres joined, as the single string the search matcher checks.
    public var genre: String? {
        let joined = (genres ?? []).joined(separator: ", ")
        return joined.isEmpty ? nil : joined
    }

    /// The publishers among the book's studios. Jellyfin stores an
    /// audiobook's publisher in the item's studios.
    public var publishers: [String] {
        (studios ?? []).map(\.name)
    }

    /// The publishers joined, as the single string the search matcher checks.
    public var publisher: String? {
        let joined = publishers.joined(separator: ", ")
        return joined.isEmpty ? nil : joined
    }

    /// The person types that name a narrator. Jellyfin 12 and newer write
    /// Narrator. Older servers write Composer, as does a newer server for a
    /// book it has not yet rescanned.
    private static let narratorPersonTypes: Set<String> = ["Narrator", "Composer"]

    /// The narrators among the book's people.
    public var narrators: [String] {
        (people ?? []).filter { Self.narratorPersonTypes.contains($0.type) }.map(\.name)
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

    /// When the book was last played, or nil when the server has never seen
    /// it played.
    public var lastPlayedDate: Date? {
        guard let timestamp = userData?.lastPlayedTimestamp else { return nil }
        return parseServerDate(timestamp)
    }

    /// Returns a copy of the book at a different resume position.
    public func withResumePosition(_ seconds: Double) -> Book {
        var copy = self
        copy.userData = BookUserData(
            playbackPositionTicks: Int64(seconds * ticksPerSecond),
            lastPlayedTimestamp: userData?.lastPlayedTimestamp
        )
        return copy
    }
}

public struct BookUserData: Codable, Hashable {
    public let playbackPositionTicks: Int64
    /// When the user last played the book, as the server writes it, or nil
    /// when the server has no record of a play.
    public let lastPlayedTimestamp: String?

    enum CodingKeys: String, CodingKey {
        case playbackPositionTicks = "PlaybackPositionTicks"
        case lastPlayedTimestamp = "LastPlayedDate"
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

public struct Studio: Codable, Hashable {
    public let name: String

    enum CodingKeys: String, CodingKey {
        case name = "Name"
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
