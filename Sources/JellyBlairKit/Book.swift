import AVFoundation
import Foundation
import Observation

/// Everything the app knows about one book. The server's fields live in the
/// current record, and the client-side state lives beside it: the chapters,
/// the transcript, the download, the stream asset, and the screen state.
/// The library creates one Book per record and every part of the app reads
/// the same object, so a change shows everywhere at once.
@MainActor
@Observable
public final class Book: Identifiable {
    public nonisolated let id: String

    /// The server's current record of the book. Every server field,
    /// including the resume position, reads from here, so the book has one
    /// source for each fact.
    public private(set) var record: BookRecord

    public private(set) var chapters: [Chapter]
    public private(set) var isFetchingChapters = false

    /// The book screen's remembered state; see BookScreenState.
    public var screenState = BookScreenState()

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
    /// Why the last download failed, cleared when a new one starts. A
    /// cancelled download leaves no message.
    public private(set) var downloadErrorMessage: String?
    @ObservationIgnored private var downloader: Downloader?

    /// True while the player holds the book's live position. Adopting a
    /// server record then keeps the local position, because the player
    /// writes the settled one back when the book closes.
    @ObservationIgnored var isPositionHeldByPlayer = false

    /// The library's hook for a changed record, so the record reaches the
    /// snapshot file and the sort orders.
    @ObservationIgnored var onRecordChanged: (() -> Void)?

    /// The library's hook for a freshly parsed stream asset, so it can
    /// bound how many stay in memory.
    @ObservationIgnored var onAssetParsed: ((Book) -> Void)?

    /// The player's hook for a finished download, so playback moves onto
    /// the file while the book is open. Set on open and cleared on close.
    @ObservationIgnored var onDownloadCompleted: (() -> Void)?

    private let client: JellyfinClient
    private let onChaptersChanged: ([Chapter]) -> Void
    @ObservationIgnored private var cachedAsset: AVURLAsset?

    init(record: BookRecord, client: JellyfinClient, initialChapters: [Chapter], onChaptersChanged: @escaping ([Chapter]) -> Void) {
        id = record.id
        self.record = record
        self.client = client
        self.chapters = initialChapters
        self.onChaptersChanged = onChaptersChanged
        if FileManager.default.fileExists(atPath: downloadedFileURL.path) {
            downloadState = .downloaded
        }
    }

    // MARK: - Record fields

    public var name: String { record.name }
    public var authors: [String] { record.authors }
    public var author: String? { record.author }
    public var narrators: [String] { record.narrators }
    public var publishers: [String] { record.publishers }
    public var genres: [String] { record.genres ?? [] }
    public var productionYear: Int? { record.productionYear }
    public var runTimeSeconds: Double { record.runTimeSeconds }
    public var fileSizeBytes: Int64? { record.fileSizeBytes }
    public var bitrateKbps: Int? { record.bitrateKbps }
    public var container: String? { record.container }
    public var codec: String? { record.codec }
    public var hasLyrics: Bool { record.hasLyrics == true }
    public var isFavorite: Bool { record.isFavorite }
    public var resumePositionSeconds: Double { record.resumePositionSeconds }

    /// True when the title, author, narrator, genre, or publisher contains
    /// the query.
    public func matches(_ query: String) -> Bool {
        record.matches(query)
    }

    public var coverURL: URL {
        client.imageURL(bookID: id)
    }

    // MARK: - Record updates

    /// Adopts a fresh server record, keeping the local position while the
    /// player holds it. Returns whether anything changed; an unchanged
    /// record writes nothing, so a no-op refresh invalidates no observers.
    @discardableResult
    func adoptRecord(_ fresh: BookRecord) -> Bool {
        let adopted = isPositionHeldByPlayer ? fresh.withResumePosition(resumePositionSeconds) : fresh
        guard adopted != record else { return false }
        record = adopted
        return true
    }

    /// Fetches the book's current server record and adopts it. On failure
    /// the known record stands.
    public func refreshFromServer() async {
        guard let fresh = await client.fetchBook(id: id), adoptRecord(fresh) else { return }
        onRecordChanged?()
    }

    /// Playback records where it has reached, so displays follow without a
    /// fetch. The record changes in memory only, so frequent writes rewrite
    /// no snapshot file. An unchanged position writes nothing.
    func recordPosition(_ seconds: Double) {
        guard seconds != resumePositionSeconds else { return }
        record = record.withResumePosition(seconds)
    }

    /// Records a settled position and reports the change, so the library
    /// persists it and an offline launch resumes here.
    func recordSettledPosition(_ seconds: Double) {
        guard seconds != resumePositionSeconds else { return }
        recordPosition(seconds)
        onRecordChanged?()
    }

    /// Records that playback started now and notifies the library, so the
    /// last-played sort follows a play without a server fetch. The next
    /// refresh adopts the server's own timestamp.
    func recordPlaybackStart() {
        record = record.withLastPlayedTimestamp(formatServerDate(Date()))
        onRecordChanged?()
    }

    /// True when the position is past the start, which is what makes the
    /// play button offer Resume and the reset available.
    public var isStarted: Bool {
        resumePositionSeconds > 0
    }

    /// The chapter the resume position lies in, once the chapters are
    /// known.
    public var resumeChapter: Chapter? {
        chapters.last(where: { $0.startSeconds <= resumePositionSeconds + Chapter.startSlackSeconds })
    }

    /// Flips the favorite mark, on the server first so the two never
    /// disagree. A failed call changes nothing.
    public func toggleFavorite() async {
        let target = !isFavorite
        guard (try? await client.setFavorite(target, bookID: id)) != nil else { return }
        record = record.withFavorite(target)
        onRecordChanged?()
    }

    /// Clears the played state and the resume position, on the server first
    /// so the two never disagree. A failed call changes nothing.
    public func resetPlayback() async {
        guard (try? await client.resetPlayback(bookID: id)) != nil else { return }
        recordSettledPosition(0)
    }

    // MARK: - Stream asset

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
            asset = client.streamAsset(bookID: id)
        }
        cachedAsset = asset
        onAssetParsed?(self)
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

    // MARK: - Download

    private var downloadedFileURL: URL {
        let name = "\(sanitizedFileComponent(id)).\(sanitizedFileComponent(record.container ?? "m4b"))"
        return DataDirectory.downloads.appendingPathComponent(name)
    }

    public var isDownloaded: Bool {
        downloadState == .downloaded
    }

    /// Downloads the book's file for offline playback.
    public func download() {
        guard downloadState == .notDownloaded else { return }
        Log.downloads.notice("Downloading \(self.name, privacy: .public) (\(self.id, privacy: .public))")
        downloadState = .downloading(nil)
        downloadErrorMessage = nil
        let downloader = Downloader(
            destination: downloadedFileURL,
            onProgress: { [weak self] progress in
                guard let self, case .downloading = self.downloadState else { return }
                self.downloadState = .downloading(progress)
            },
            onFinish: { [weak self] outcome in
                guard let self else { return }
                self.downloader = nil
                // The next streamAsset() call picks up the file or the stream.
                self.releaseAsset()
                switch outcome {
                case .succeeded:
                    Log.downloads.notice("Downloaded \(self.name, privacy: .public)")
                    self.downloadState = .downloaded
                    self.onDownloadCompleted?()
                case .failed(let message):
                    if let message {
                        Log.downloads.error("Download of \(self.name, privacy: .public) failed: \(message, privacy: .public)")
                    }
                    self.downloadState = .notDownloaded
                    self.downloadErrorMessage = message
                }
            }
        )
        self.downloader = downloader
        downloader.start(client.streamRequest(bookID: id))
        Task { await fillOfflineCaches() }
    }

    /// Fetches the chapters and the transcript beside the file download, so
    /// a downloaded book carries them offline even when the screen's own
    /// fetches failed or never ran. Cheap when they are already cached.
    private func fillOfflineCaches() async {
        async let chapters: Void = fetchChaptersIfNeeded()
        async let lyrics: Void = fetchLyricsIfNeeded()
        await chapters
        await lyrics
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

    // MARK: - Chapters

    /// Reads the chapters from the file unless they are already known.
    public func fetchChaptersIfNeeded() async {
        guard chapters.isEmpty, !isFetchingChapters else { return }
        isFetchingChapters = true
        defer { isFetchingChapters = false }
        _ = await loadAndStoreChapters()
    }

    /// Reads the chapters again from the file. The old list stays in place
    /// until the re-read succeeds, like the transcript's refresh.
    public func refreshChapters() async {
        guard !isFetchingChapters else { return }
        isFetchingChapters = true
        defer { isFetchingChapters = false }
        releaseAsset()
        _ = await loadAndStoreChapters()
    }

    /// Reads the chapters, stores them, and notifies the library. An empty
    /// result can mean a failed read, so it stores only real chapters and
    /// reports whether it did.
    private func loadAndStoreChapters() async -> Bool {
        let loaded = await loadChapters()
        guard !loaded.isEmpty else { return false }
        chapters = loaded
        onChaptersChanged(loaded)
        return true
    }

    // MARK: - Lyrics

    /// Reads the transcript from the disk cache or the server unless it is
    /// already known.
    public func fetchLyricsIfNeeded() async {
        guard lyrics.isEmpty, !isFetchingLyrics else { return }
        isFetchingLyrics = true
        defer { isFetchingLyrics = false }
        let cached = lyricsStore.load(bookID: id)
        guard cached.isEmpty else {
            lyrics = cached
            return
        }
        await fetchLyricsFromServer()
    }

    /// Fetches the transcript from the server again. The old lines and their
    /// disk cache survive a failed fetch, but any successful answer wins,
    /// including an empty one.
    public func refreshLyrics() async {
        guard !isFetchingLyrics else { return }
        isFetchingLyrics = true
        defer { isFetchingLyrics = false }
        await fetchLyricsFromServer()
    }

    /// Applies the server's answer: new lines replace the cache, and no
    /// lines clear it, so a sidecar removed on the server disappears here
    /// too. A failed fetch changes nothing.
    private func fetchLyricsFromServer() async {
        guard let loaded = try? await client.fetchLyrics(bookID: id) else { return }
        lyrics = loaded
        if loaded.isEmpty {
            lyricsStore.delete(bookID: id)
        } else {
            lyricsStore.save(loaded, for: id)
        }
    }

    // MARK: - Chapter reading

    private func loadChapters() async -> [Chapter] {
        let asset = streamAsset()
        let groups = await loadChapterGroups(from: asset)
        var loaded: [Chapter] = []
        for (index, group) in groups.enumerated() {
            let title = await chapterTitle(of: group) ?? "Chapter \(index + 1)"
            let start = group.timeRange.start.seconds
            let end = index + 1 < groups.count ? groups[index + 1].timeRange.start.seconds : runTimeSeconds
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
