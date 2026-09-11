import Foundation

/// Persists the last fetched library snapshot, so the app has books to show
/// before the network answers and when the server is unreachable.
struct LibraryStore {
    private var fileURL: URL {
        DataDirectory.root.appendingPathComponent("library.json")
    }

    func load() -> [Book] {
        readCacheFile([Book].self, from: fileURL, label: "library") ?? []
    }

    func save(_ books: [Book]) {
        writeCacheFile(books, to: fileURL, label: "library")
    }
}
