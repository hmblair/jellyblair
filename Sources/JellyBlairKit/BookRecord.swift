import Foundation

/// One audiobook as the server describes it: the wire format of the item
/// responses and the disk format of the cached library snapshot. The app
/// reads books through the Book class, which holds the current record.
public struct BookRecord: Codable, Identifiable, Hashable {
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
    /// When the client fetched this record from the server. The client
    /// stamps every fetched record, so it is nil only in snapshots written
    /// before the stamp existed.
    public private(set) var lastSyncedTimestamp: String?

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
        case lastSyncedTimestamp = "LastSyncedDate"
    }

    /// The audio container format, for naming downloaded files.
    public var container: String? {
        mediaSources?.first?.container
    }

    /// The audio file's size in bytes, when the server reports it.
    public var fileSizeBytes: Int64? {
        mediaSources?.first?.size
    }

    /// The audio stream's codec, when the server reports it.
    public var codec: String? {
        mediaSources?.first?.mediaStreams?.first(where: { $0.type == "Audio" })?.codec
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

    public var isFavorite: Bool {
        userData?.isFavorite == true
    }

    /// True when the server marks the book played, which it keeps across
    /// re-plays until the played state is reset.
    public var isPlayed: Bool {
        userData?.played == true
    }

    /// When the client last fetched this record from the server.
    public var lastSyncedDate: Date? {
        guard let timestamp = lastSyncedTimestamp else { return nil }
        return parseServerDate(timestamp)
    }

    /// Returns a copy of the record stamped at a sync time.
    public func withSyncTimestamp(_ timestamp: String) -> BookRecord {
        var copy = self
        copy.lastSyncedTimestamp = timestamp
        return copy
    }

    /// Returns a copy of the book at a different resume position.
    public func withResumePosition(_ seconds: Double) -> BookRecord {
        var copy = self
        copy.userData = BookUserData(
            playbackPositionTicks: Int64(seconds * ticksPerSecond),
            lastPlayedTimestamp: userData?.lastPlayedTimestamp,
            isFavorite: userData?.isFavorite,
            played: userData?.played
        )
        return copy
    }

    /// Returns a copy of the book with a new last-played timestamp.
    public func withLastPlayedTimestamp(_ timestamp: String) -> BookRecord {
        var copy = self
        copy.userData = BookUserData(
            playbackPositionTicks: userData?.playbackPositionTicks ?? 0,
            lastPlayedTimestamp: timestamp,
            isFavorite: userData?.isFavorite,
            played: userData?.played
        )
        return copy
    }

    /// Returns a copy of the book at a different played state. The server
    /// clears the resume position with either change, so the copy does too.
    public func withPlayed(_ played: Bool) -> BookRecord {
        var copy = self
        copy.userData = BookUserData(
            playbackPositionTicks: 0,
            lastPlayedTimestamp: userData?.lastPlayedTimestamp,
            isFavorite: userData?.isFavorite,
            played: played
        )
        return copy
    }

    /// Returns a copy of the book at a different favorite state.
    public func withFavorite(_ isFavorite: Bool) -> BookRecord {
        var copy = self
        copy.userData = BookUserData(
            playbackPositionTicks: userData?.playbackPositionTicks ?? 0,
            lastPlayedTimestamp: userData?.lastPlayedTimestamp,
            isFavorite: isFavorite,
            played: userData?.played
        )
        return copy
    }
}

public struct BookUserData: Codable, Hashable {
    public let playbackPositionTicks: Int64
    /// When the user last played the book, as the server writes it, or nil
    /// when the server has no record of a play.
    public let lastPlayedTimestamp: String?
    public let isFavorite: Bool?
    /// Whether the user has finished the book. The server keeps this true
    /// across re-plays.
    public let played: Bool?

    enum CodingKeys: String, CodingKey {
        case playbackPositionTicks = "PlaybackPositionTicks"
        case lastPlayedTimestamp = "LastPlayedDate"
        case isFavorite = "IsFavorite"
        case played = "Played"
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
    public let mediaStreams: [MediaStream]?

    enum CodingKeys: String, CodingKey {
        case container = "Container"
        case size = "Size"
        case bitrate = "Bitrate"
        case mediaStreams = "MediaStreams"
    }
}

public struct MediaStream: Codable, Hashable {
    public let type: String?
    public let codec: String?

    enum CodingKeys: String, CodingKey {
        case type = "Type"
        case codec = "Codec"
    }
}
