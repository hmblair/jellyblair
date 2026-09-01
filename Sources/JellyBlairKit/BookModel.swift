import AVFoundation
import Foundation
import Observation

/// Everything the app knows about one book: metadata, chapters, the resume
/// position, and the stream asset. Created when the book is first visited,
/// then read instead of re-fetched. The resume position updates from the
/// server on refresh and from playback when the book closes, so displays and
/// the Resume button always agree with what will actually happen.
@MainActor
@Observable
public final class BookModel: Identifiable {
    public nonisolated let book: Book

    public private(set) var resumePositionSeconds: Double
    public private(set) var chapters: [Chapter]
    public private(set) var isFetchingChapters = false

    private let client: JellyfinClient
    private let onChaptersChanged: ([Chapter]) -> Void
    @ObservationIgnored private var cachedAsset: AVURLAsset?

    init(book: Book, client: JellyfinClient, initialChapters: [Chapter], onChaptersChanged: @escaping ([Chapter]) -> Void) {
        self.book = book
        self.client = client
        self.chapters = initialChapters
        self.onChaptersChanged = onChaptersChanged
        resumePositionSeconds = book.resumePositionSeconds
    }

    public nonisolated var id: String { book.id }

    public var coverURL: URL {
        client.imageURL(for: book)
    }

    /// The stream asset, shared between chapter reading and playback so the
    /// file's index data downloads and parses once.
    public func streamAsset() -> AVURLAsset {
        if let cachedAsset {
            return cachedAsset
        }
        let asset = client.streamAsset(for: book)
        cachedAsset = asset
        return asset
    }

    /// Drops the parsed asset to bound memory; it recreates lazily on demand.
    func releaseAsset() {
        cachedAsset = nil
    }

    /// Downloads and parses the asset's index ahead of playback, so pressing
    /// Play on a visited book starts quickly. Cheap when already warm.
    public func prewarmAsset() async {
        _ = try? await streamAsset().load(.isPlayable)
    }

    // MARK: - Resume position

    /// Fetches the server's current position. On failure the known value stands.
    public func refreshUserData() async {
        guard let fresh = await client.fetchBook(id: book.id) else { return }
        resumePositionSeconds = fresh.resumePositionSeconds
    }

    /// Playback records where it left the book, so reopening needs no fetch.
    func recordPosition(_ seconds: Double) {
        resumePositionSeconds = seconds
    }

    // MARK: - Chapters

    /// Reads the chapters from the file unless they are already known.
    public func fetchChaptersIfNeeded() async {
        guard chapters.isEmpty, !isFetchingChapters else { return }
        isFetchingChapters = true
        defer { isFetchingChapters = false }
        let loaded = await loadChapters()
        // An empty result can mean a failed read, so only keep real chapters.
        guard !loaded.isEmpty else { return }
        chapters = loaded
        onChaptersChanged(loaded)
    }

    /// Reads the chapters again from the file. The old list and its disk
    /// cache survive unless the re-read succeeds.
    public func refreshChapters() async {
        guard !isFetchingChapters else { return }
        isFetchingChapters = true
        defer { isFetchingChapters = false }
        let previous = chapters
        chapters = []
        releaseAsset()
        let loaded = await loadChapters()
        guard !loaded.isEmpty else {
            chapters = previous
            return
        }
        chapters = loaded
        onChaptersChanged(loaded)
    }

    // MARK: - Chapter reading

    private func loadChapters() async -> [Chapter] {
        let asset = streamAsset()
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
