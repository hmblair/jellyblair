import Foundation

/// Persists the last fetched library snapshot, so the app has books to show
/// before the network answers and when the server is unreachable.
struct LibraryStore {
    private var fileURL: URL {
        DataDirectory.root.appendingPathComponent("library.json")
    }

    func load() -> [BookRecord] {
        readCacheFile([BookRecord].self, from: fileURL, label: "library") ?? []
    }

    func save(_ records: [BookRecord]) {
        writeCacheFile(records, to: fileURL, label: "library")
    }
}
