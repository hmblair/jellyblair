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

    public private(set) var lyrics: [LyricLine] = []
    public private(set) var isFetchingLyrics = false
    private let lyricsStore = LyricsStore()

    public enum DownloadState: Equatable {
        case notDownloaded
        /// Fraction complete, or nil while the total size is unknown.
        case downloading(Double?)
        case downloaded
    }

    public private(set) var downloadState: DownloadState = .notDownloaded
    @ObservationIgnored private var downloader: Downloader?

    private let client: JellyfinClient
    private let onChaptersChanged: ([Chapter]) -> Void
    @ObservationIgnored private var cachedAsset: AVURLAsset?

    init(book: Book, client: JellyfinClient, initialChapters: [Chapter], onChaptersChanged: @escaping ([Chapter]) -> Void) {
        self.book = book
        self.client = client
        self.chapters = initialChapters
        self.onChaptersChanged = onChaptersChanged
        resumePositionSeconds = book.resumePositionSeconds
        if FileManager.default.fileExists(atPath: downloadedFileURL.path) {
            downloadState = .downloaded
        }
    }

    public nonisolated var id: String { book.id }

    public var coverURL: URL {
        client.imageURL(for: book)
    }

    /// The stream asset: the downloaded file when present, the server
    /// stream otherwise. Chapter reading and playback share it, so the
    /// file's index data downloads and parses once.
    public func streamAsset() -> AVURLAsset {
        if let cachedAsset {
            return cachedAsset
        }
        let asset: AVURLAsset
        if downloadState == .downloaded {
            asset = AVURLAsset(url: downloadedFileURL)
        } else {
            asset = client.streamAsset(for: book)
        }
        cachedAsset = asset
        return asset
    }

    // MARK: - Download

    private var downloadedFileURL: URL {
        let directory = jellyBlairDataDirectory().appendingPathComponent("downloads")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("\(book.id).\(book.container ?? "m4b")")
    }

    /// Downloads the book's file for offline playback.
    public func download() {
        guard downloadState == .notDownloaded else { return }
        downloadState = .downloading(nil)
        let downloader = Downloader(
            destination: downloadedFileURL,
            onProgress: { [weak self] progress in
                guard let self, case .downloading = self.downloadState else { return }
                self.downloadState = .downloading(progress)
            },
            onFinish: { [weak self] succeeded in
                guard let self else { return }
                self.downloader = nil
                self.downloadState = succeeded ? .downloaded : .notDownloaded
                // Playback switches source on the next open.
                self.releaseAsset()
            }
        )
        self.downloader = downloader
        downloader.start(client.streamRequest(for: book))
    }

    public func cancelDownload() {
        guard case .downloading = downloadState else { return }
        downloader?.cancel()
        downloader = nil
        downloadState = .notDownloaded
    }

    /// Deletes the downloaded file; playback returns to streaming.
    public func removeDownload() {
        guard downloadState == .downloaded else { return }
        try? FileManager.default.removeItem(at: downloadedFileURL)
        downloadState = .notDownloaded
        releaseAsset()
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

    // MARK: - Lyrics

    /// Reads the transcript from the disk cache or the server unless it is
    /// already known.
    public func fetchLyricsIfNeeded() async {
        guard lyrics.isEmpty, !isFetchingLyrics else { return }
        isFetchingLyrics = true
        defer { isFetchingLyrics = false }
        let cached = lyricsStore.load(bookID: book.id)
        guard cached.isEmpty else {
            lyrics = cached
            return
        }
        await fetchLyricsFromServer()
    }

    /// Fetches the transcript from the server again. The old lines and their
    /// disk cache survive unless the fetch succeeds.
    public func refreshLyrics() async {
        guard !isFetchingLyrics else { return }
        isFetchingLyrics = true
        defer { isFetchingLyrics = false }
        await fetchLyricsFromServer()
    }

    private func fetchLyricsFromServer() async {
        guard let loaded = try? await client.fetchLyrics(bookID: book.id), !loaded.isEmpty else { return }
        lyrics = loaded
        lyricsStore.save(loaded, for: book.id)
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
