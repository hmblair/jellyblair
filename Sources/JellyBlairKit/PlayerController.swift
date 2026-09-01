#if canImport(AppKit)
import AppKit
#else
import UIKit
#endif
import AVFoundation
import Foundation
import Observation

/// Owns the AVPlayer, the chapter list, and playback progress reports for one book at a time.
@MainActor
@Observable
public final class PlayerController {
    private let client: JellyfinClient

    public private(set) var book: Book?
    public private(set) var chapters: [Chapter] = []
    public private(set) var currentChapterIndex: Int?
    public private(set) var isPlaying = false
    public private(set) var currentTime: Double = 0
    public private(set) var duration: Double = 0
    public private(set) var playbackErrorMessage: String?

    /// True once the player item can actually play. Transport controls and
    /// seeking stay disabled until then.
    public private(set) var isReady = false

    public private(set) var playbackSpeed: Double

    private var player: AVPlayer?
    private var timeObserver: Any?
    private var statusObservation: NSKeyValueObservation?
    private var playbackEndObserver: NSObjectProtocol?
    private var terminationObserver: NSObjectProtocol?
    private var progressReportTimer: Timer?

    /// Number of seeks in flight. The time observer is ignored while this is nonzero,
    /// so the bar does not jump back to the pre-seek position.
    private var pendingSeekCount = 0

    /// Incremented on each open. Work that resumes from an await under a stale
    /// generation discards its result instead of touching the newer book's state.
    private var openGeneration = 0
    private var openTask: Task<Void, Never>?

    /// Chapters already read from each book's file, keyed by book ID.
    private var chapterCache: [String: [Chapter]]
    private let chapterStore = ChapterStore()

    /// True after a start report was sent, so stop reports only follow real sessions.
    private var hasActiveSession = false

    /// Positions at which books were last closed in this run.
    /// Fallback for reopening while the server is unreachable.
    private var lastKnownPositions: [String: Double] = [:]

    /// Seconds between progress reports to the server.
    private static let progressReportInterval: TimeInterval = 10

    /// Seconds to wait for a new player item before declaring the open failed.
    private static let readyTimeout: TimeInterval = 8

    private static let playbackSpeedDefaultsKey = "playbackSpeed"

    private let nowPlaying = NowPlayingCenter()
    private var currentArtwork: PlatformImage?

    /// Live band levels of the playing audio, for the now-playing bars.
    public let audioMeter = AudioLevelMeter()

    public init(client: JellyfinClient) {
        self.client = client
        chapterCache = chapterStore.load()
        let storedSpeed = UserDefaults.standard.double(forKey: Self.playbackSpeedDefaultsKey)
        playbackSpeed = storedSpeed > 0 ? storedSpeed : 1.0
        observeAppTermination()
        nowPlaying.attach(to: self)
    }

    deinit {
        // Owned by SwiftUI state, so deallocation happens on the main thread.
        MainActor.assumeIsolated {
            progressReportTimer?.invalidate()
            if let timeObserver, let player {
                player.removeTimeObserver(timeObserver)
            }
            if let terminationObserver {
                NotificationCenter.default.removeObserver(terminationObserver)
            }
        }
    }

    public var currentChapter: Chapter? {
        guard let index = currentChapterIndex, chapters.indices.contains(index) else { return nil }
        return chapters[index]
    }

    /// The range the seek bar covers: the current chapter, or the whole book when there are no chapters.
    public var seekRange: ClosedRange<Double> {
        guard let chapter = currentChapter else {
            return 0...max(duration, 1)
        }
        return chapter.startSeconds...max(chapter.endSeconds, chapter.startSeconds + 1)
    }

    // MARK: - Opening and closing books

    public func open(_ newBook: Book) {
        openTask?.cancel()
        openGeneration += 1
        let generation = openGeneration
        openTask = Task {
            await performOpen(newBook, generation: generation)
        }
    }

    /// Re-opens the current book after a failed open, once the server is back.
    public func retryCurrentBook() {
        guard let book else { return }
        open(book)
    }

    private func performOpen(_ newBook: Book, generation: Int) async {
        await closeCurrentBook()
        guard generation == openGeneration else { return }

        // The new book's metadata shows immediately with the snapshot position;
        // the fresh server position corrects it when the fetch returns.
        book = newBook
        playbackErrorMessage = nil
        isReady = false
        duration = newBook.runTimeSeconds
        setChapters(chapterCache[newBook.id] ?? [])
        setCurrentTime(newBook.resumePositionSeconds)

        let startPosition = await resolveResumePosition(for: newBook)
        guard generation == openGeneration else { return }
        setCurrentTime(startPosition)

        let asset = client.streamAsset(for: newBook)
        let item = AVPlayerItem(asset: asset)
        let newPlayer = AVPlayer(playerItem: item)
        player = newPlayer
        observeTime(of: newPlayer)
        observeFailure(of: item)
        observePlaybackEnd(of: item)

        let ready = await waitUntilReady(item)
        guard generation == openGeneration else { return }
        guard ready else {
            handlePlaybackFailure(item.error?.localizedDescription ?? "Cannot reach the server.")
            return
        }
        isReady = true

        let audioTrack = try? await asset.loadTracks(withMediaType: .audio).first
        guard generation == openGeneration else { return }
        if let audioTrack, let audioMix = audioMeter.makeAudioMix(for: audioTrack) {
            item.audioMix = audioMix
        }

        if startPosition > 0 {
            await seek(to: startPosition)
            guard generation == openGeneration else { return }
        }
        await loadArtwork(for: newBook, generation: generation)
        await loadChaptersIfNeeded(for: newBook, from: asset, generation: generation)
    }

    private func loadArtwork(for book: Book, generation: Int) async {
        let image = await CoverImageLoader.shared.image(for: book.id, from: client.imageURL(for: book))
        guard generation == openGeneration else { return }
        currentArtwork = image
        syncNowPlaying()
    }

    /// Waits for the player item to become playable, with the app's own timeout.
    /// AVFoundation alone can sit in an unknown state for minutes when offline.
    private func waitUntilReady(_ item: AVPlayerItem) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: .seconds(Self.readyTimeout))
        while ContinuousClock.now < deadline {
            switch item.status {
            case .readyToPlay:
                return true
            case .failed:
                return false
            default:
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
        return false
    }

    /// Prefers the server's current position, since the library list is a stale
    /// snapshot from launch. Falls back to a locally recorded position offline.
    private func resolveResumePosition(for book: Book) async -> Double {
        if let fresh = await client.fetchBook(id: book.id) {
            return fresh.resumePositionSeconds
        }
        if let local = lastKnownPositions[book.id] {
            return local
        }
        return book.resumePositionSeconds
    }

    private func closeCurrentBook() async {
        guard let book else { return }
        player?.pause()
        removeObservers()
        stopProgressReports()
        let position = currentTime
        lastKnownPositions[book.id] = position
        let hadSession = hasActiveSession
        self.book = nil
        player = nil
        isPlaying = false
        isReady = false
        hasActiveSession = false
        playbackErrorMessage = nil
        currentArtwork = nil
        audioMeter.reset()
        syncNowPlaying()
        if hadSession {
            await client.reportPlaybackStopped(bookID: book.id, positionSeconds: position)
        }
    }

    // MARK: - Chapters

    /// Discards the cached chapters and reads them again from the file.
    public func refreshChapters() async {
        guard let book else { return }
        let generation = openGeneration
        chapterCache.removeValue(forKey: book.id)
        chapterStore.save(chapterCache)
        setChapters([])
        let asset = client.streamAsset(for: book)
        await loadChaptersIfNeeded(for: book, from: asset, generation: generation)
    }

    private func loadChaptersIfNeeded(for book: Book, from asset: AVURLAsset, generation: Int) async {
        guard chapterCache[book.id] == nil else { return }
        let loaded = await loadChapters(from: asset, bookDuration: book.runTimeSeconds)
        // An empty result can mean a failed read, so only cache real chapters.
        guard !loaded.isEmpty else { return }
        chapterCache[book.id] = loaded
        chapterStore.save(chapterCache)
        guard generation == openGeneration else { return }
        setChapters(loaded)
    }

    private func loadChapters(from asset: AVURLAsset, bookDuration: Double) async -> [Chapter] {
        let groups = await loadChapterGroups(from: asset)
        var loaded: [Chapter] = []
        for (index, group) in groups.enumerated() {
            let title = await chapterTitle(of: group) ?? "Chapter \(index + 1)"
            let start = group.timeRange.start.seconds
            let end = index + 1 < groups.count ? groups[index + 1].timeRange.start.seconds : bookDuration
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

    // MARK: - Transport

    public func play() {
        guard isReady, book != nil else { return }
        // At the end of the book the player cannot advance, so play restarts it.
        if currentTime >= duration - 0.5 {
            Task {
                await seek(to: 0)
                startPlayback()
            }
            return
        }
        startPlayback()
    }

    private func startPlayback() {
        guard isReady, let book else { return }
        player?.rate = Float(playbackSpeed)
        isPlaying = true
        if !hasActiveSession {
            hasActiveSession = true
            startProgressReports(for: book)
        }
        syncNowPlaying()
    }

    public func pause() {
        player?.pause()
        isPlaying = false
        audioMeter.reset()
        reportProgressNow()
        syncNowPlaying()
    }

    public func setPlaybackSpeed(_ speed: Double) {
        playbackSpeed = speed
        UserDefaults.standard.set(speed, forKey: Self.playbackSpeedDefaultsKey)
        if isPlaying {
            player?.rate = Float(speed)
        }
        syncNowPlaying()
    }

    public func togglePlayback() {
        isPlaying ? pause() : play()
    }

    public func seek(to seconds: Double) async {
        guard isReady, player != nil else { return }
        let target = max(0, min(seconds, duration))
        setCurrentTime(target)
        pendingSeekCount += 1
        let time = CMTime(seconds: target, preferredTimescale: Int32(ticksPerSecond))
        await player?.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero)
        pendingSeekCount -= 1
        // Playing to the end zeroes the player's rate, so a seek away from the
        // end must re-assert it to keep the playing state truthful.
        if isPlaying {
            player?.rate = Float(playbackSpeed)
        }
        syncNowPlaying()
    }

    public func skip(by seconds: Double) async {
        await seek(to: currentTime + seconds)
    }

    /// Jumps to a chapter and plays it, like clicking a song in a music app.
    public func jump(to chapter: Chapter) async {
        await seek(to: chapter.startSeconds)
        play()
    }

    /// Seconds into a chapter beyond which the previous button restarts it
    /// instead of going to the previous chapter, like a music app.
    private static let chapterRestartThreshold: Double = 3

    public func nextChapter() async {
        guard let index = currentChapterIndex, index + 1 < chapters.count else { return }
        await seek(to: chapters[index + 1].startSeconds)
    }

    public func previousChapter() async {
        guard let chapter = currentChapter else {
            if currentTime > Self.chapterRestartThreshold {
                await seek(to: 0)
            }
            return
        }
        let elapsedInChapter = currentTime - chapter.startSeconds
        if elapsedInChapter > Self.chapterRestartThreshold || chapter.index == 0 {
            await seek(to: chapter.startSeconds)
        } else {
            await seek(to: chapters[chapter.index - 1].startSeconds)
        }
    }

    // MARK: - Time and chapter tracking

    private func setCurrentTime(_ seconds: Double) {
        currentTime = seconds
        refreshCurrentChapterIndex()
    }

    private func setChapters(_ newChapters: [Chapter]) {
        chapters = newChapters
        refreshCurrentChapterIndex()
    }

    /// Writes the index only when it changes, so views that depend on the
    /// chapter alone do not re-render on every time tick.
    private func refreshCurrentChapterIndex() {
        let index = chapters.last(where: { $0.startSeconds <= currentTime + 0.5 })?.index
        if index != currentChapterIndex {
            currentChapterIndex = index
            syncNowPlaying()
        }
    }

    /// Pushes the current state to the system Now Playing center.
    private func syncNowPlaying() {
        nowPlaying.update(
            bookTitle: book?.name,
            author: book?.author,
            chapterTitle: currentChapter?.title,
            elapsed: currentTime,
            duration: duration,
            rate: playbackSpeed,
            isPlaying: isPlaying,
            artwork: currentArtwork
        )
    }

    // MARK: - Player observation

    private func observeTime(of player: AVPlayer) {
        let interval = CMTime(seconds: 1.0 / 30.0, preferredTimescale: 600)
        timeObserver = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            MainActor.assumeIsolated {
                guard let self, self.pendingSeekCount == 0 else { return }
                self.setCurrentTime(time.seconds)
            }
        }
    }

    private func observeFailure(of item: AVPlayerItem) {
        statusObservation = item.observe(\.status) { [weak self] item, _ in
            guard item.status == .failed else { return }
            let message = item.error?.localizedDescription ?? "Playback failed."
            Task { @MainActor in
                self?.handlePlaybackFailure(message)
            }
        }
    }

    private func observePlaybackEnd(of item: AVPlayerItem) {
        playbackEndObserver = NotificationCenter.default.addObserver(
            forName: AVPlayerItem.didPlayToEndTimeNotification,
            object: item,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.handlePlaybackEnded()
            }
        }
    }

    private func removeObservers() {
        if let timeObserver, let player {
            player.removeTimeObserver(timeObserver)
        }
        timeObserver = nil
        statusObservation?.invalidate()
        statusObservation = nil
        if let playbackEndObserver {
            NotificationCenter.default.removeObserver(playbackEndObserver)
        }
        playbackEndObserver = nil
    }

    private func handlePlaybackFailure(_ message: String) {
        playbackErrorMessage = message
        isPlaying = false
        isReady = false
        removeObservers()
        player = nil
        stopProgressReports()
        syncNowPlaying()
    }

    private func handlePlaybackEnded() {
        guard let book else { return }
        isPlaying = false
        setCurrentTime(duration)
        lastKnownPositions[book.id] = duration
        audioMeter.reset()
        stopProgressReports()
        syncNowPlaying()
        Task {
            await client.reportPlaybackStopped(bookID: book.id, positionSeconds: duration)
        }
    }

    // MARK: - Progress reports

    private func startProgressReports(for book: Book) {
        Task {
            await client.reportPlaybackStarted(bookID: book.id, positionSeconds: currentTime)
        }
        progressReportTimer = Timer.scheduledTimer(withTimeInterval: Self.progressReportInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.reportProgressNow()
            }
        }
    }

    private func stopProgressReports() {
        progressReportTimer?.invalidate()
        progressReportTimer = nil
    }

    private func reportProgressNow() {
        guard let book, hasActiveSession else { return }
        let position = currentTime
        let paused = !isPlaying
        Task {
            await client.reportPlaybackProgress(bookID: book.id, positionSeconds: position, isPaused: paused)
        }
    }

    /// Sends a final stop report before the process exits, blocking briefly so the
    /// request has a chance to leave. Async reporting cannot finish during termination.
    private func observeAppTermination() {
        terminationObserver = NotificationCenter.default.addObserver(
            forName: Self.terminationNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let book = self.book, self.hasActiveSession else { return }
                self.client.reportPlaybackStoppedBlocking(bookID: book.id, positionSeconds: self.currentTime)
            }
        }
    }

    #if canImport(AppKit)
    private static let terminationNotification = NSApplication.willTerminateNotification
    #else
    private static let terminationNotification = UIApplication.willTerminateNotification
    #endif
}
