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

public struct BookUserData: Decodable, Hashable {
    public let playbackPositionTicks: Int64

    enum CodingKeys: String, CodingKey {
        case playbackPositionTicks = "PlaybackPositionTicks"
    }
}

public struct Person: Decodable, Hashable {
    public let name: String
    public let type: String

    enum CodingKeys: String, CodingKey {
        case name = "Name"
        case type = "Type"
    }
}

public struct Book: Decodable, Identifiable, Hashable {
    public let id: String
    public let name: String
    public let runTimeTicks: Int64?
    public let userData: BookUserData?
    public let albumArtist: String?
    public let artists: [String]?
    public let people: [Person]?

    enum CodingKeys: String, CodingKey {
        case id = "Id"
        case name = "Name"
        case runTimeTicks = "RunTimeTicks"
        case userData = "UserData"
        case albumArtist = "AlbumArtist"
        case artists = "Artists"
        case people = "People"
    }

    public var author: String? {
        if let albumArtist, !albumArtist.isEmpty {
            return albumArtist
        }
        let joined = (artists ?? []).joined(separator: ", ")
        return joined.isEmpty ? nil : joined
    }

    /// Jellyfin stores audiobook narrators as people with the Composer type.
    public var narrator: String? {
        let names = (people ?? []).filter { $0.type == "Composer" }.map(\.name)
        return names.isEmpty ? nil : names.joined(separator: ", ")
    }

    public var runTimeSeconds: Double {
        Double(runTimeTicks ?? 0) / ticksPerSecond
    }

    public var resumePositionSeconds: Double {
        Double(userData?.playbackPositionTicks ?? 0) / ticksPerSecond
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
