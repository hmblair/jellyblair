import Foundation

/// Persists the last fetched library snapshot, so the app has books to show
/// before the network answers and when the server is unreachable.
struct LibraryStore {
    private var fileURL: URL {
        DataDirectory.root.appendingPathComponent("library.json")
    }

    func load() -> [Book] {
        guard let data = try? Data(contentsOf: fileURL) else { return [] }
        return (try? JSONDecoder().decode([Book].self, from: data)) ?? []
    }

    func save(_ books: [Book]) {
        guard let data = try? JSONEncoder().encode(books) else { return }
        try? data.write(to: fileURL)
    }
}
