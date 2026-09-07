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

    /// True while the player intends to play. The player's own state is the
    /// source of truth; updatePlayingState mirrors it here and is the one
    /// place that writes it.
    public private(set) var isPlaying = false

    /// The position anchor, written on playback events: open, seek, pause,
    /// playback end, and every effective timebase rate change.
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
    private var timeControlObservation: NSKeyValueObservation?
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

    /// The session scope's hook for a settled position, which it writes
    /// into the library's cached snapshot. The periodic report does not use
    /// it, because each write replaces the whole snapshot file.
    @ObservationIgnored public var onPositionRecorded: ((String, Double) -> Void)?

    /// True after a start report was sent, so stop reports only follow real sessions.
    private var hasActiveSession = false

    /// Seeks currently landing. Until the count returns to zero the timebase
    /// still reads the pre-seek position, so reanchors wait and the anchor
    /// stays pinned at the seek target.
    private var seeksInFlight = 0

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
        observePlayingState(of: newPlayer)

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

    /// Re-reads the now-playing artwork from the cover cache.
    public func refreshArtwork() async {
        guard let currentModel else { return }
        await loadArtwork(for: currentModel, generation: openGeneration)
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

    /// Closes the loaded book: playback stops and the playback bar goes away.
    public func close() async {
        await closeCurrentBook()
    }

    private func closeCurrentBook() async {
        guard let book else { return }
        player?.pause()
        // Detaches the meter's tap before the item goes away. Releasing an
        // item while the render thread can still be inside the tap is a
        // use-after-free that corrupts the heap.
        player?.currentItem?.audioMix = nil
        // The transition runs directly here: the observation's hop to the
        // main actor would land after the player is gone.
        updatePlayingState(false)
        removeObservers()
        stopProgressReports()
        let position = currentTime
        recordPosition(position, for: book.id)
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

    /// Reads the loaded book's chapters again. The old list stays in place
    /// until the re-read succeeds.
    public func refreshChapters() async {
        guard let model = currentModel else { return }
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

    /// Commands only: the playing flag and its side effects follow from
    /// the player's state change, through updatePlayingState.
    private func startPlayback() {
        guard isReady else { return }
        player?.rate = Float(playbackSpeed)
    }

    public func pause() {
        player?.pause()
    }

    /// The one writer of the playing flag, with the side effects of each
    /// transition. Every pause runs the same effects here, whether the app
    /// or the system paused the player.
    private func updatePlayingState(_ playing: Bool) {
        guard playing != isPlaying else { return }
        isPlaying = playing
        if playing {
            if let book, !hasActiveSession {
                hasActiveSession = true
                startProgressReports(for: book)
            }
        } else {
            reanchorFromPlayer()
            audioMeter.reset()
            reportProgressNow()
        }
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
        // The displays sit at the target while the seek lands.
        setAnchor(position: target, rate: 0)
        seeksInFlight += 1
        let time = CMTime(seconds: target, preferredTimescale: Int32(ticksPerSecond))
        await player?.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero)
        seeksInFlight -= 1
        // A superseded seek leaves the rest to the newest one.
        guard seeksInFlight == 0 else { return }
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
        guard seeksInFlight == 0 else { return }
        guard let timebase = player?.currentItem?.timebase else {
            setAnchor(position: anchor.position(), rate: 0)
            return
        }
        let reported = timebase.time.seconds
        let position = reported.isFinite ? reported : anchor.position()
        setAnchor(position: position, rate: timebase.rate)
    }

    /// An unchanged list writes nothing, so a no-op refresh invalidates no
    /// observers and rebuilds no chapter list.
    private func setChapters(_ newChapters: [Chapter]) {
        guard newChapters != chapters else { return }
        chapters = newChapters
        refreshCurrentChapterIndex()
        installChapterBoundaryObserver()
    }

    /// Writes the index only when it changes, so views that depend on the
    /// chapter alone do not re-render on every time tick.
    private func refreshCurrentChapterIndex() {
        let index = chapters.last(where: { $0.startSeconds <= currentTime + Chapter.startSlackSeconds })?.index
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

    /// Fires exactly when playback crosses a chapter start, so the chapter
    /// index refreshes without time polling. The anchor stays untouched: a
    /// mid-play timebase read can report a position ahead of the audible
    /// content on a seeked network stream.
    private func installChapterBoundaryObserver() {
        removeChapterBoundaryObserver()
        guard let player else { return }
        let starts = chapters.map(\.startSeconds).filter { $0 > 0 }
        guard !starts.isEmpty else { return }
        let times = starts.map { NSValue(time: CMTime(seconds: $0, preferredTimescale: 600)) }
        boundaryObserver = player.addBoundaryTimeObserver(forTimes: times, queue: .main) { [weak self] in
            MainActor.assumeIsolated {
                self?.refreshCurrentChapterIndex()
            }
        }
    }

    private func removeChapterBoundaryObserver() {
        if let boundaryObserver, let player {
            player.removeTimeObserver(boundaryObserver)
        }
        boundaryObserver = nil
    }

    /// Observes a notification the media subsystem posts from its own
    /// threads, running the action on the main actor.
    ///
    /// Every media notification must register through this helper. It takes
    /// delivery on the posting thread and hops to the main actor itself:
    /// main-queue delivery makes the media thread wait for the main thread
    /// while holding the notification center's lock, and a timebase
    /// teardown finalizing on the main thread waits for that lock, so the
    /// two deadlock when one book closes while another starts.
    private func observeMediaNotification(
        _ name: Notification.Name,
        from object: Any,
        action: @escaping @MainActor (PlayerController) -> Void
    ) -> NSObjectProtocol {
        NotificationCenter.default.addObserver(forName: name, object: object, queue: nil) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                action(self)
            }
        }
    }

    /// Reanchors when the timebase's effective rate changes. The notification
    /// arrives at the exact moments rendering starts, stalls, resumes, or
    /// changes speed, so the projection follows the audio without polling.
    private func observeTimebaseRate(of item: AVPlayerItem) {
        guard let timebase = item.timebase else { return }
        timebaseRateObserver = observeMediaNotification(
            .init(kCMTimebaseNotification_EffectiveRateChanged as String),
            from: timebase
        ) { player in
            player.reanchorFromPlayer()
        }
    }

    /// Derives the playing flag from the player's own state. Every change
    /// arrives here, including pauses the system performs itself, such as
    /// the automatic pause when headphones disconnect. A rebuffering stall
    /// reports the waiting status, not the paused one, so it stays a
    /// playing state.
    private func observePlayingState(of player: AVPlayer) {
        timeControlObservation = player.observe(\.timeControlStatus) { [weak self] player, _ in
            let playing = player.timeControlStatus != .paused
            Task { @MainActor in
                self?.updatePlayingState(playing)
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
        playbackEndObserver = observeMediaNotification(AVPlayerItem.didPlayToEndTimeNotification, from: item) { player in
            player.handlePlaybackEnded()
        }
    }

    private func removeObservers() {
        removeChapterBoundaryObserver()
        statusObservation?.invalidate()
        statusObservation = nil
        timeControlObservation?.invalidate()
        timeControlObservation = nil
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
        updatePlayingState(false)
        isReady = false
        removeObservers()
        // See closeCurrentBook: the tap must detach before the item goes away.
        player?.currentItem?.audioMix = nil
        player = nil
        stopProgressReports()
        syncNowPlaying()
    }

    private func handlePlaybackEnded() {
        guard let book else { return }
        updatePlayingState(false)
        setAnchor(position: duration, rate: 0)
        recordPosition(duration, for: book.id)
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

    /// Publishes a settled position to the book model and the library's
    /// cached snapshot. Both hold it after the player closes the book.
    private func recordPosition(_ seconds: Double, for bookID: String) {
        currentModel?.recordPosition(seconds)
        onPositionRecorded?(bookID, seconds)
    }

    /// Publishes the position from one read: the model and the server take
    /// the same value. The two never disagree by more than one interval
    /// while the book plays.
    private func reportProgressNow() {
        guard let book, hasActiveSession else { return }
        let position = currentTime
        let paused = !isPlaying
        currentModel?.recordPosition(position)
        Task {
            await client.reportPlaybackProgress(bookID: book.id, positionSeconds: position, isPaused: paused)
        }
    }

    /// Records the final position and reports the stop before the process exits.
    /// The report blocks briefly, because async work cannot finish during termination.
    private func observeAppTermination() {
        terminationObserver = NotificationCenter.default.addObserver(
            forName: Self.terminationNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let book = self.book, self.hasActiveSession else { return }
                let position = self.currentTime
                // The local write comes first: the report below can block
                // for a second.
                self.recordPosition(position, for: book.id)
                self.client.reportPlaybackStoppedBlocking(bookID: book.id, positionSeconds: position)
            }
        }
    }

    #if canImport(AppKit)
    private static let terminationNotification = NSApplication.willTerminateNotification
    #else
    private static let terminationNotification = UIApplication.willTerminateNotification
    #endif
}
