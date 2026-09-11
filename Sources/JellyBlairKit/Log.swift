import Foundation
import os

/// The app's loggers, one per area, all under one subsystem so a single
/// Console filter (subsystem == "JellyBlair") shows every line the app
/// writes.
///
/// Levels: error marks a failure whose effect the user can notice, warning
/// marks a degraded state the app absorbs, and notice marks the lifecycle
/// breadcrumbs that give a later failure its context. Notice and above
/// persist, so `log show` finds them after the fact; info and debug do not.
enum Log {
    private static let subsystem = "JellyBlair"

    /// The player, its item observers, and playback reports.
    static let playback = Logger(subsystem: subsystem, category: "playback")
    /// Requests to the Jellyfin server.
    static let network = Logger(subsystem: subsystem, category: "network")
    /// Downloads for offline listening.
    static let downloads = Logger(subsystem: subsystem, category: "downloads")
    /// The on-disk caches: library, chapters, transcripts, covers.
    static let storage = Logger(subsystem: subsystem, category: "storage")
    /// Sign-in, session restore, and server reachability.
    static let session = Logger(subsystem: subsystem, category: "session")
}

/// Reads a JSON cache file. An absent file is normal cache state and stays
/// silent; an unreadable or undecodable one is logged. Returns nil when
/// the value cannot be read.
func readCacheFile<Value: Decodable>(_ type: Value.Type, from url: URL, label: String) -> Value? {
    guard FileManager.default.fileExists(atPath: url.path) else { return nil }
    do {
        return try JSONDecoder().decode(type, from: Data(contentsOf: url))
    } catch {
        Log.storage.error("Cannot read the \(label, privacy: .public) cache: \(String(describing: error), privacy: .public)")
        return nil
    }
}

/// Writes a JSON cache file, logging any failure.
func writeCacheFile<Value: Encodable>(_ value: Value, to url: URL, label: String) {
    do {
        try JSONEncoder().encode(value).write(to: url)
    } catch {
        Log.storage.error("Cannot write the \(label, privacy: .public) cache: \(String(describing: error), privacy: .public)")
    }
}
