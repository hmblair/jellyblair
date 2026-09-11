import Foundation

/// Persists each book's transcript on disk, so a fetched transcript survives
/// restarts and shows when the server is unreachable. Each book gets its own
/// file, since a transcript can hold thousands of lines.
struct LyricsStore {
    private func fileURL(for bookID: String) -> URL {
        DataDirectory.lyrics.appendingPathComponent("\(sanitizedFileComponent(bookID)).json")
    }

    func load(bookID: String) -> [LyricLine] {
        readCacheFile([LyricLine].self, from: fileURL(for: bookID), label: "transcript") ?? []
    }

    func save(_ lines: [LyricLine], for bookID: String) {
        writeCacheFile(lines, to: fileURL(for: bookID), label: "transcript")
    }

    func delete(bookID: String) {
        try? FileManager.default.removeItem(at: fileURL(for: bookID))
    }
}
