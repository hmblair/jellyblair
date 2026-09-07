import Foundation

/// Persists each book's transcript on disk, so a fetched transcript survives
/// restarts and shows when the server is unreachable. Each book gets its own
/// file, since a transcript can hold thousands of lines.
struct LyricsStore {
    private func fileURL(for bookID: String) -> URL {
        DataDirectory.lyrics.appendingPathComponent("\(sanitizedFileComponent(bookID)).json")
    }

    func load(bookID: String) -> [LyricLine] {
        guard let data = try? Data(contentsOf: fileURL(for: bookID)) else { return [] }
        return (try? JSONDecoder().decode([LyricLine].self, from: data)) ?? []
    }

    func save(_ lines: [LyricLine], for bookID: String) {
        guard let data = try? JSONEncoder().encode(lines) else { return }
        try? data.write(to: fileURL(for: bookID))
    }

    func delete(bookID: String) {
        try? FileManager.default.removeItem(at: fileURL(for: bookID))
    }
}
