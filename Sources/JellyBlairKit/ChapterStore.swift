import Foundation

/// Persists the per-book chapter lists on disk, so cached chapters survive restarts
/// and show when the server is unreachable.
struct ChapterStore {
    private var fileURL: URL {
        DataDirectory.root.appendingPathComponent("chapters.json")
    }

    func load() -> [String: [Chapter]] {
        guard let data = try? Data(contentsOf: fileURL) else { return [:] }
        return (try? JSONDecoder().decode([String: [Chapter]].self, from: data)) ?? [:]
    }

    func save(_ chapters: [String: [Chapter]]) {
        guard let data = try? JSONEncoder().encode(chapters) else { return }
        try? data.write(to: fileURL)
    }
}
