#if canImport(AppKit)
import AppKit
#else
import UIKit
#endif
import AVFoundation
import Foundation
import Observation

/// A playback position fixed to a wall-clock moment, with the rate carrying
/// it forward. Displays project the current position from it, so playback
/// needs no periodic time updates.
public struct PlaybackAnchor: Equatable {
    public let positionSeconds: Double
    public let date: Date
    public let rate: Double

    /// The position the anchor projects to at the given moment.
    public func position(at date: Date = Date()) -> Double {
        positionSeconds + max(0, date.timeIntervalSince(self.date)) * rate
    }

    /// The moment playback reaches a position, or nil while not moving.
    public func date(forPosition position: Double) -> Date? {
        guard rate > 0 else { return nil }
        return date.addingTimeInterval((position - positionSeconds) / rate)
    }
}

/// Owns the AVPlayer, the chapter list, and playback progress reports for one book at a time.
@MainActor
@Observable
public final class PlayerController {
    private let client: JellyfinClient

    public private(set) var book: Book?
    public private(set) var chapters: [Chapter] = []
    public private(set) var currentChapterIndex: Int?
    public private(set) var isPlaying = false

    /// Whether lists follow the listening position, keeping it centered as
    /// it moves. On by default and shared across screens; scrolling a list
    /// by hand turns it off, the tracking button turns it back on.
    public var isTrackingPosition = true

    /// The position anchor, written on playback events: play, pause, seek,
    /// speed change, chapter boundary, and the periodic progress report.
    public private(set) var anchor = PlaybackAnchor(positionSeconds: 0, date: .distantPast, rate: 0)

    public private(set) var duration: Double = 0

    /// The projected position now. For a display that must stay current over
    /// time, use projectedTime(at:) inside a TimelineView instead.
    public var currentTime: Double { projectedTime(at: Date()) }

    /// The position the anchor projects to at the given moment.
    public func projectedTime(at date: Date) -> Double {
        min(max(0, duration), anchor.position(at: date))
    }
    public private(set) var playbackErrorMessage: String?

    /// True once the player item can actually play. Transport controls and
    /// seeking stay disabled until then.
    public private(set) var isReady = false

    public private(set) var playbackSpeed: Double

    private var player: AVPlayer?
    private var boundaryObserver: Any?
    private var statusObservation: NSKeyValueObservation?
    private var timebaseRateObserver: NSObjectProtocol?
    private var playbackEndObserver: NSObjectProtocol?
    private var terminationObserver: NSObjectProtocol?
    private var progressReportTimer: Timer?

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
            stopProgressReports()
            removeObservers()
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
        setAnchor(position: startPosition, rate: 0)

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
        installChapterBoundaryObserver()
        observeTimebaseRate(of: item)

        let audioTrack = try? await asset.loadTracks(withMediaType: .audio).first
        guard generation == openGeneration else { return }
        if let audioTrack, let audioMix = audioMeter.makeAudioMix(for: audioTrack) {
            item.audioMix = audioMix
        }

        if startPosition > 0 {
            await seek(to: startPosition)
            guard generation == openGeneration else { return }
        }
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
        isPlaying = false
        reanchorFromPlayer()
        removeObservers()
        stopProgressReports()
        let position = currentTime
        currentModel?.recordPosition(position)
        let hadSession = hasActiveSession
        self.book = nil
        currentModel = nil
        player = nil
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
        reanchorFromPlayer()
        if !hasActiveSession {
            hasActiveSession = true
            startProgressReports(for: book)
        }
        syncNowPlaying()
    }

    public func pause() {
        player?.pause()
        isPlaying = false
        reanchorFromPlayer()
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
        reanchorFromPlayer()
        syncNowPlaying()
    }

    public func togglePlayback() {
        isPlaying ? pause() : play()
    }

    public func seek(to seconds: Double) async {
        guard isReady, player != nil else { return }
        let target = max(0, min(seconds, duration))
        // The displays sit at the target while the seek lands.
        setAnchor(position: target, rate: 0)
        let time = CMTime(seconds: target, preferredTimescale: Int32(ticksPerSecond))
        await player?.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero)
        // Playing to the end zeroes the player's rate, so a seek away from the
        // end must re-assert it to keep the playing state truthful.
        if isPlaying {
            player?.rate = Float(playbackSpeed)
        }
        reanchorFromPlayer()
        syncNowPlaying()
    }

    public func skip(by seconds: Double) async {
        await seek(to: currentTime + seconds)
    }

    /// Jumps to a chapter and plays it, like clicking a song in a music app.
    public func jump(to chapter: Chapter) async {
        await jump(toSeconds: chapter.startSeconds)
    }

    /// Jumps to a position and plays, like clicking a transcript line.
    public func jump(toSeconds seconds: Double) async {
        await seek(to: seconds)
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

    private func setAnchor(position: Double, rate: Double) {
        anchor = PlaybackAnchor(positionSeconds: position, date: Date(), rate: rate)
        refreshCurrentChapterIndex()
    }

    /// Pins the anchor to the item's timebase, the clock that drives audio
    /// rendering. The timebase time is the exact playback position. The
    /// timebase rate is zero while the player primes or rebuffers, so the
    /// projection freezes and resumes with the audio.
    private func reanchorFromPlayer() {
        guard let timebase = player?.currentItem?.timebase else {
            setAnchor(position: anchor.position(), rate: 0)
            return
        }
        let reported = timebase.time.seconds
        let position = reported.isFinite ? reported : anchor.position()
        setAnchor(position: position, rate: timebase.rate)
    }

    private func setChapters(_ newChapters: [Chapter]) {
        chapters = newChapters
        refreshCurrentChapterIndex()
        installChapterBoundaryObserver()
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

    /// Fires exactly when playback crosses a chapter start, replacing time
    /// polling: the anchor and chapter index refresh only at boundaries.
    private func installChapterBoundaryObserver() {
        removeChapterBoundaryObserver()
        guard let player else { return }
        let starts = chapters.map(\.startSeconds).filter { $0 > 0 }
        guard !starts.isEmpty else { return }
        let times = starts.map { NSValue(time: CMTime(seconds: $0, preferredTimescale: 600)) }
        boundaryObserver = player.addBoundaryTimeObserver(forTimes: times, queue: .main) { [weak self] in
            MainActor.assumeIsolated {
                self?.reanchorFromPlayer()
            }
        }
    }

    private func removeChapterBoundaryObserver() {
        if let boundaryObserver, let player {
            player.removeTimeObserver(boundaryObserver)
        }
        boundaryObserver = nil
    }

    /// Reanchors when the timebase's effective rate changes. The notification
    /// arrives at the exact moments rendering starts, stalls, resumes, or
    /// changes speed, so the projection follows the audio without polling.
    private func observeTimebaseRate(of item: AVPlayerItem) {
        guard let timebase = item.timebase else { return }
        timebaseRateObserver = NotificationCenter.default.addObserver(
            forName: .init(kCMTimebaseNotification_EffectiveRateChanged as String),
            object: timebase,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.reanchorFromPlayer()
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
        removeChapterBoundaryObserver()
        statusObservation?.invalidate()
        statusObservation = nil
        if let timebaseRateObserver {
            NotificationCenter.default.removeObserver(timebaseRateObserver)
        }
        timebaseRateObserver = nil
        if let playbackEndObserver {
            NotificationCenter.default.removeObserver(playbackEndObserver)
        }
        playbackEndObserver = nil
    }

    private func handlePlaybackFailure(_ message: String) {
        guard playbackErrorMessage == nil else { return }
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
        setAnchor(position: duration, rate: 0)
        currentModel?.recordPosition(duration)
        audioMeter.reset()
        stopProgressReports()
        // The stop report below ends the session; replaying starts a new one.
        hasActiveSession = false
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
