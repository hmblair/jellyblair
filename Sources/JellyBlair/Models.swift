import Foundation

/// Number of Jellyfin ticks in one second.
let ticksPerSecond: Double = 10_000_000

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

struct BookUserData: Decodable, Hashable {
    let playbackPositionTicks: Int64

    enum CodingKeys: String, CodingKey {
        case playbackPositionTicks = "PlaybackPositionTicks"
    }
}

struct Person: Decodable, Hashable {
    let name: String
    let type: String

    enum CodingKeys: String, CodingKey {
        case name = "Name"
        case type = "Type"
    }
}

struct Book: Decodable, Identifiable, Hashable {
    let id: String
    let name: String
    let runTimeTicks: Int64?
    let userData: BookUserData?
    let albumArtist: String?
    let artists: [String]?
    let people: [Person]?

    enum CodingKeys: String, CodingKey {
        case id = "Id"
        case name = "Name"
        case runTimeTicks = "RunTimeTicks"
        case userData = "UserData"
        case albumArtist = "AlbumArtist"
        case artists = "Artists"
        case people = "People"
    }

    var author: String? {
        if let albumArtist, !albumArtist.isEmpty {
            return albumArtist
        }
        let joined = (artists ?? []).joined(separator: ", ")
        return joined.isEmpty ? nil : joined
    }

    /// Jellyfin stores audiobook narrators as people with the Composer type.
    var narrator: String? {
        let names = (people ?? []).filter { $0.type == "Composer" }.map(\.name)
        return names.isEmpty ? nil : names.joined(separator: ", ")
    }

    var runTimeSeconds: Double {
        Double(runTimeTicks ?? 0) / ticksPerSecond
    }

    var resumePositionSeconds: Double {
        Double(userData?.playbackPositionTicks ?? 0) / ticksPerSecond
    }
}

/// A chapter marker read from the audio file itself.
struct Chapter: Identifiable, Hashable, Codable {
    let index: Int
    let title: String
    let startSeconds: Double
    let endSeconds: Double

    var id: Int { index }

    var durationSeconds: Double {
        max(0, endSeconds - startSeconds)
    }
}
