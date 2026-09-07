import Foundation
import Observation

/// Registry of BookModels: one per visited book, created on first access and
/// reused thereafter, so every part of the app reads the same cached state.
/// Persists chapter lists on disk and bounds how many parsed stream assets
/// stay in memory.
@MainActor
@Observable
public final class BookCatalog {
    private let client: JellyfinClient

    // Caches are implementation detail: exempt from observation, so views
    // calling model(for:) during body evaluation do not invalidate themselves.
    @ObservationIgnored private var models: [String: BookModel] = [:]
    @ObservationIgnored private var chapterCache: [String: [Chapter]]
    private let chapterStore = ChapterStore()

    /// Most recently used first. Models beyond the cap release their assets.
    @ObservationIgnored private var assetUseOrder: [String] = []
    private static let retainedAssetCount = 3

    public init(client: JellyfinClient) {
        self.client = client
        chapterCache = chapterStore.load()
    }

    public func model(for book: Book) -> BookModel {
        if let existing = models[book.id] {
            noteUse(of: book.id)
            return existing
        }
        let model = BookModel(
            book: book,
            client: client,
            initialChapters: chapterCache[book.id] ?? []
        ) { [weak self] chapters in
            self?.storeChapters(chapters, for: book.id)
        }
        models[book.id] = model
        noteUse(of: book.id)
        return model
    }

    /// Pushes fresh library snapshots into the existing models, so the
    /// filters and rows agree with the server after a refresh. The loaded
    /// book is skipped: the player owns its position and writes it back on
    /// close.
    public func applySnapshots(_ books: [Book], skippingBookID: String?) {
        for book in books {
            guard book.id != skippingBookID else { continue }
            models[book.id]?.applySnapshot(book)
        }
    }

    public func isDownloaded(_ book: Book) -> Bool {
        model(for: book).downloadState == .downloaded
    }

    public func isInProgress(_ book: Book) -> Bool {
        model(for: book).isInProgress
    }

    public func coverURL(for book: Book) -> URL {
        client.imageURL(for: book)
    }

    private func storeChapters(_ chapters: [Chapter], for bookID: String) {
        if chapters.isEmpty {
            chapterCache.removeValue(forKey: bookID)
        } else {
            chapterCache[bookID] = chapters
        }
        chapterStore.save(chapterCache)
    }

    /// Tracks which books were used most recently and releases the parsed
    /// stream assets of the rest, since each can hold megabytes of index data.
    private func noteUse(of bookID: String) {
        // Reads during view passes hit the same book repeatedly; the front
        // check keeps them free of list churn.
        guard assetUseOrder.first != bookID else { return }
        assetUseOrder.removeAll { $0 == bookID }
        assetUseOrder.insert(bookID, at: 0)
        for staleID in assetUseOrder.dropFirst(Self.retainedAssetCount) {
            models[staleID]?.releaseAsset()
        }
    }
}
