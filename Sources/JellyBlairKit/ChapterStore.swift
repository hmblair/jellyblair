import Foundation

/// Persists the per-book chapter lists on disk, so cached chapters survive restarts
/// and show when the server is unreachable.
struct ChapterStore {
    private var fileURL: URL {
        DataDirectory.root.appendingPathComponent("chapters.json")
    }

    func load() -> [String: [Chapter]] {
        readCacheFile([String: [Chapter]].self, from: fileURL, label: "chapters") ?? [:]
    }

    func save(_ chapters: [String: [Chapter]]) {
        writeCacheFile(chapters, to: fileURL, label: "chapters")
    }
}
