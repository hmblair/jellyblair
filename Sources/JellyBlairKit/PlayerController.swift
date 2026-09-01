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

    /// The model of the loaded book; playback reads from and records into it.
    private var currentModel: BookModel?

    /// True after a start report was sent, so stop reports only follow real sessions.
    private var hasActiveSession = false

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

    public func open(_ model: BookModel, playWhenReady: Bool = false, startAtSeconds: Double? = nil) {
        openTask?.cancel()
        openGeneration += 1
        let generation = openGeneration
        openTask = Task {
            await performOpen(model, generation: generation, playWhenReady: playWhenReady, startAtSeconds: startAtSeconds)
        }
    }

    /// Re-opens the current book after a failed open, once the server is back.
    public func retryCurrentBook() {
        guard let currentModel else { return }
        open(currentModel)
    }

    private func performOpen(_ model: BookModel, generation: Int, playWhenReady: Bool, startAtSeconds: Double?) async {
        await closeCurrentBook()
        guard generation == openGeneration else { return }

        // The model already knows the resume position, so the target shows
        // immediately and the Resume button does exactly what it said.
        let newBook = model.book
        currentModel = model
        book = newBook
        playbackErrorMessage = nil
        isReady = false
        duration = newBook.runTimeSeconds
        setChapters(model.chapters)
        let startPosition = startAtSeconds ?? model.resumePositionSeconds
        setCurrentTime(startPosition)

        let asset = model.streamAsset()
        let item = AVPlayerItem(asset: asset)
        let newPlayer = AVPlayer(playerItem: item)
        player = newPlayer
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
        // The time observer starts only now: installed earlier, its initial
        // callback would report position zero and clobber the staged position.
        observeTime(of: newPlayer)
        if playWhenReady {
            play()
        }
        await loadArtwork(for: model, generation: generation)
        await model.fetchChaptersIfNeeded()
        guard generation == openGeneration else { return }
        setChapters(model.chapters)
    }

    private func loadArtwork(for model: BookModel, generation: Int) async {
        let image = await CoverImageLoader.shared.image(for: model.book.id, from: model.coverURL)
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

    private func closeCurrentBook() async {
        guard let book else { return }
        player?.pause()
        removeObservers()
        stopProgressReports()
        let position = currentTime
        currentModel?.recordPosition(position)
        let hadSession = hasActiveSession
        self.book = nil
        currentModel = nil
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

    /// Discards the loaded book's cached chapters and reads them again.
    public func refreshChapters() async {
        guard let model = currentModel else { return }
        setChapters([])
        await model.refreshChapters()
        guard currentModel === model else { return }
        setChapters(model.chapters)
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
    /// Times are chapter-scoped, matching every other display in the app.
    private func syncNowPlaying() {
        let scopeStart = currentChapter?.startSeconds ?? 0
        let scopeDuration = currentChapter?.durationSeconds ?? duration
        nowPlaying.update(
            bookTitle: book?.name,
            author: book?.author,
            chapterTitle: currentChapter?.title,
            elapsed: max(0, currentTime - scopeStart),
            duration: scopeDuration,
            rate: playbackSpeed,
            isPlaying: isPlaying,
            artwork: currentArtwork
        )
    }

    /// Seeks to a position relative to the current chapter, for the system
    /// scrubber, whose times are chapter-scoped.
    func seekWithinCurrentChapter(to seconds: Double) async {
        let scopeStart = currentChapter?.startSeconds ?? 0
        await seek(to: scopeStart + seconds)
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
        currentModel?.recordPosition(duration)
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
