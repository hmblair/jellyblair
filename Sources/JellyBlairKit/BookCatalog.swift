import AVFoundation
import Foundation
import Observation

/// Library-item knowledge independent of playback: chapter lists, fresh user
/// data, and cover URLs. Chapters cache in memory and on disk.
@MainActor
@Observable
public final class BookCatalog {
    private let client: JellyfinClient

    private var chapterCache: [String: [Chapter]]
    private let chapterStore = ChapterStore()

    /// Book IDs whose chapters are being read.
    private var chapterFetchesInFlight: Set<String> = []

    public init(client: JellyfinClient) {
        self.client = client
        chapterCache = chapterStore.load()
    }

    public func coverURL(for book: Book) -> URL {
        client.imageURL(for: book)
    }

    /// Fetches the book with current user data, such as the resume position.
    public func freshBook(_ book: Book) async -> Book? {
        await client.fetchBook(id: book.id)
    }

    // MARK: - Chapters

    public func cachedChapters(for book: Book) -> [Chapter] {
        chapterCache[book.id] ?? []
    }

    public func isFetchingChapters(for book: Book) -> Bool {
        chapterFetchesInFlight.contains(book.id)
    }

    /// Reads the book's chapters from its file and caches them.
    /// Does nothing when they are already cached or being read.
    public func fetchChapters(for book: Book) async {
        guard chapterCache[book.id] == nil, !chapterFetchesInFlight.contains(book.id) else { return }
        chapterFetchesInFlight.insert(book.id)
        defer { chapterFetchesInFlight.remove(book.id) }
        let loaded = await loadChapters(for: book)
        // An empty result can mean a failed read, so only cache real chapters.
        guard !loaded.isEmpty else { return }
        chapterCache[book.id] = loaded
        chapterStore.save(chapterCache)
    }

    /// Discards a book's cached chapters, so the next fetch rereads the file.
    public func invalidateChapters(for book: Book) {
        chapterCache.removeValue(forKey: book.id)
        chapterStore.save(chapterCache)
    }

    // MARK: - Chapter reading

    private func loadChapters(for book: Book) async -> [Chapter] {
        let asset = client.streamAsset(for: book)
        let groups = await loadChapterGroups(from: asset)
        var loaded: [Chapter] = []
        for (index, group) in groups.enumerated() {
            let title = await chapterTitle(of: group) ?? "Chapter \(index + 1)"
            let start = group.timeRange.start.seconds
            let end = index + 1 < groups.count ? groups[index + 1].timeRange.start.seconds : book.runTimeSeconds
            loaded.append(Chapter(index: index, title: title, startSeconds: start, endSeconds: end))
        }
        return loaded
    }

    /// Reads chapter groups for the preferred language, then falls back to
    /// whatever chapter locale the file declares (often undefined).
    private func loadChapterGroups(from asset: AVURLAsset) async -> [AVTimedMetadataGroup] {
        let preferred = (try? await asset.loadChapterMetadataGroups(bestMatchingPreferredLanguages: ["en"])) ?? []
        if !preferred.isEmpty {
            return preferred
        }
        let locales = (try? await asset.load(.availableChapterLocales)) ?? []
        guard let locale = locales.first else { return [] }
        return (try? await asset.loadChapterMetadataGroups(withTitleLocale: locale, containingItemsWithCommonKeys: [])) ?? []
    }

    private func chapterTitle(of group: AVTimedMetadataGroup) async -> String? {
        let titleItems = AVMetadataItem.metadataItems(from: group.items, filteredByIdentifier: .commonIdentifierTitle)
        guard let item = titleItems.first else { return nil }
        return try? await item.load(.stringValue)
    }
}
