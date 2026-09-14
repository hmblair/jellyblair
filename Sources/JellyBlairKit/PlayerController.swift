#if canImport(AppKit)
import AppKit
#else
import UIKit
#endif
import AVFoundation
import Foundation
import Observation
import os

/// A playback position fixed to a wall-clock moment, with the rate carrying
/// it forward. Displays project the current position from it, so playback
/// needs no periodic time updates.
public struct PlaybackAnchor: Equatable {
    public let positionSeconds: Double
    public let date: Date
    public let rate: Double
    /// The position the listener last asked for. The projection never
    /// falls below it, because the item timebase can report a time just
    /// before a seek target while the audio starts.
    public let requestedSeconds: Double

    /// The position the anchor projects to at the given moment, never
    /// before the requested position.
    public func position(at date: Date = Date()) -> Double {
        max(requestedSeconds, positionSeconds + max(0, date.timeIntervalSince(self.date)) * rate)
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
    public private(set) var anchor = PlaybackAnchor(positionSeconds: 0, date: .distantPast, rate: 0, requestedSeconds: 0)

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
    private var playbackFailedToEndObserver: NSObjectProtocol?
    private var stallObserver: NSObjectProtocol?
    private var errorLogObserver: NSObjectProtocol?
    private var terminationObserver: NSObjectProtocol?
    private var progressReportTimer: Timer?

    #if os(iOS)
    private var interruptionObserver: NSObjectProtocol?
    /// True when the current interruption cut off live playback, which is
    /// what makes resuming at its end appropriate.
    private var wasPlayingBeforeInterruption = false
    /// True while the app is in the background, where the meter's tap is
    /// detached; see syncAudioMeterTap.
    private var isAppInBackground = false
    private var lifecycleObservers: [NSObjectProtocol] = []
    #endif

    /// Incremented on each open. Work that resumes from an await under a stale
    /// generation discards its result instead of touching the newer book's state.
    private var openGeneration = 0
    private var openTask: Task<Void, Never>?

    /// True after a start report was sent, so stop reports only follow real sessions.
    private var hasActiveSession = false

    /// Seeks currently landing. Until the count returns to zero the timebase
    /// still reads the pre-seek position, so reanchors wait and the anchor
    /// stays pinned at the seek target.
    private var seeksInFlight = 0

    /// The position the listener last asked for. Every anchor carries it.
    private var requestedSeconds: Double = 0

    /// Seconds between progress reports to the server.
    private static let progressReportInterval: TimeInterval = 10

    /// Slack on the report timer. A report has no deadline, so its fire
    /// can ride wakeups that happen anyway instead of forcing its own.
    private static let progressReportTolerance: TimeInterval = 1

    /// Seconds to wait for a new player item before declaring the open failed.
    private static let readyTimeout: TimeInterval = 8

    private static let playbackSpeedDefaultsKey = "playbackSpeed"

    private let nowPlaying = NowPlayingCenter()
    private var currentArtwork: PlatformImage?

    /// Live band levels of the playing audio, for the now-playing bars.
    public let audioMeter = AudioLevelMeter()

    /// The audio track of the item the meter taps, kept so the tap can
    /// re-attach when the app returns to the foreground.
    private var meterTrack: AVAssetTrack?

    public init(client: JellyfinClient) {
        self.client = client
        let storedSpeed = UserDefaults.standard.double(forKey: Self.playbackSpeedDefaultsKey)
        playbackSpeed = storedSpeed > 0 ? storedSpeed : 1.0
        observeAppTermination()
        #if os(iOS)
        observeAudioSessionInterruptions()
        observeAppLifecycle()
        #endif
        nowPlaying.attach(to: self)
    }

    deinit {
        // Owned by SwiftUI state, so deallocation happens on the main thread.
        MainActor.assumeIsolated {
            stopProgressReports()
            removeObservers()
            nowPlaying.detach()
            if let terminationObserver {
                NotificationCenter.default.removeObserver(terminationObserver)
            }
            #if os(iOS)
            if let interruptionObserver {
                NotificationCenter.default.removeObserver(interruptionObserver)
            }
            for observer in lifecycleObservers {
                NotificationCenter.default.removeObserver(observer)
            }
            #endif
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

    public func open(_ book: Book, playWhenReady: Bool = false, startAtSeconds: Double? = nil) {
        openTask?.cancel()
        openGeneration += 1
        let generation = openGeneration
        openTask = Task {
            await performOpen(book, generation: generation, playWhenReady: playWhenReady, startAtSeconds: startAtSeconds)
        }
    }

    /// Re-opens the current book after a failed open, once the server is back.
    public func retryCurrentBook() {
        guard let book else { return }
        open(book)
    }

    private func performOpen(_ newBook: Book, generation: Int, playWhenReady: Bool, startAtSeconds: Double?) async {
        await closeCurrentBook()
        guard generation == openGeneration else { return }

        book = newBook
        // From here the player writes the live position into the book, and
        // a server record cannot move it; see adoptRecord.
        newBook.isPositionHeldByPlayer = true
        newBook.onDownloadCompleted = { [weak self] in
            Task { await self?.adoptDownloadedFile() }
        }
        Log.playback.notice("Opening \(newBook.name, privacy: .public) (\(newBook.id, privacy: .public)) at \(startAtSeconds ?? newBook.resumePositionSeconds, format: .fixed(precision: 1))s")
        playbackErrorMessage = nil
        isReady = false
        duration = newBook.runTimeSeconds
        setChapters(newBook.chapters)
        let startPosition = startAtSeconds ?? newBook.resumePositionSeconds
        requestedSeconds = startPosition
        setAnchor(position: startPosition, rate: 0)

        let asset = newBook.streamAsset()
        let item = AVPlayerItem(asset: asset)
        let newPlayer = AVPlayer(playerItem: item)
        player = newPlayer
        observeFailure(of: item)
        observePlaybackEnd(of: item)
        observePlaybackTrouble(of: item)
        observePlayingState(of: newPlayer)

        let ready = await waitUntilReady(item)
        guard generation == openGeneration else { return }
        guard ready else {
            handlePlaybackFailure(item.error?.localizedDescription ?? String(localized: "Cannot reach the server."))
            return
        }
        isReady = true
        installChapterBoundaryObserver()
        observeTimebaseRate(of: item)

        let audioTrack = try? await asset.loadTracks(withMediaType: .audio).first
        guard generation == openGeneration else { return }
        setMeterSource(track: audioTrack)

        if startPosition > 0 {
            await seek(to: startPosition)
            guard generation == openGeneration else { return }
        }
        if playWhenReady {
            play()
        }
        await loadArtwork(for: newBook, generation: generation)
        await newBook.fetchChaptersIfNeeded()
        guard generation == openGeneration else { return }
        setChapters(newBook.chapters)
    }

    /// Re-reads the now-playing artwork from the cover cache.
    public func refreshArtwork() async {
        guard let book else { return }
        await loadArtwork(for: book, generation: openGeneration)
    }

    private func loadArtwork(for book: Book, generation: Int) async {
        let image = await CoverImageLoader.shared.image(for: book.id, from: book.coverURL)
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
        Log.playback.notice("Closing \(book.name, privacy: .public) at \(self.currentTime, format: .fixed(precision: 1))s")
        player?.pause()
        // Detaches the meter's tap before the item goes away. Releasing an
        // item while the render thread can still be inside the tap is a
        // use-after-free that corrupts the heap.
        player?.currentItem?.audioMix = nil
        meterTrack = nil
        // The transition runs directly here: the observation's hop to the
        // main actor would land after the player is gone.
        updatePlayingState(false)
        removeObservers()
        stopProgressReports()
        let position = currentTime
        book.recordSettledPosition(position)
        book.isPositionHeldByPlayer = false
        book.onDownloadCompleted = nil
        let hadSession = hasActiveSession
        self.book = nil
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

    // MARK: - Download adoption

    /// Moves the open book's playback onto its downloaded file the moment
    /// the download completes. The stream and the download carry the same
    /// file, so the position, the playing state, and the reporting session
    /// all carry over.
    private func adoptDownloadedFile() async {
        guard let player, let book, isReady else { return }
        guard book.downloadState == .downloaded else { return }
        let generation = openGeneration

        let asset = book.streamAsset()
        let audioTrack = try? await asset.loadTracks(withMediaType: .audio).first
        let item = await preparedItem(from: asset, near: currentTime)
        guard swapStillApplies(generation, player) else { return }

        Log.playback.notice("Adopting the downloaded file at \(self.currentTime, format: .fixed(precision: 1))s")
        // Muted until the seek below lands, so the swap is silence, not a repeat.
        let volume = player.volume
        defer { player.volume = volume }
        player.volume = 0

        let position = currentTime
        replaceItem(of: player, with: item)

        let ready = await waitUntilReady(item)
        guard swapStillApplies(generation, player) else { return }
        guard ready else {
            handlePlaybackFailure(item.error?.localizedDescription ?? String(localized: "Playback failed."))
            return
        }
        observeTimebaseRate(of: item)
        await seek(to: position)
        guard swapStillApplies(generation, player) else { return }
        setMeterSource(track: audioTrack)
    }

    /// Prewarms the asset and pre-seeks a new item to the target, so the
    /// item becomes ready quickly and near the position once attached.
    private func preparedItem(from asset: AVURLAsset, near seconds: Double) async -> AVPlayerItem {
        _ = try? await asset.load(.isPlayable)
        let item = AVPlayerItem(asset: asset)
        let time = CMTime(seconds: seconds, preferredTimescale: Int32(ticksPerSecond))
        await item.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero)
        return item
    }

    /// Swaps the player's item, moving the item observers and the meter's
    /// tap with it. The player keeps its rate, so the playing state carries.
    private func replaceItem(of player: AVPlayer, with item: AVPlayerItem) {
        // See closeCurrentBook: the tap must detach before the item goes away.
        // The track empties with it, so a foreground return mid-swap cannot
        // attach the old asset's track to the new item.
        player.currentItem?.audioMix = nil
        meterTrack = nil
        removeItemObservers()
        player.replaceCurrentItem(with: item)
        observeFailure(of: item)
        observePlaybackEnd(of: item)
        observePlaybackTrouble(of: item)
    }

    /// False once another book opened or the player was rebuilt mid-swap.
    private func swapStillApplies(_ generation: Int, _ player: AVPlayer) -> Bool {
        generation == openGeneration && self.player === player
    }

    // MARK: - Audio meter tap

    /// Remembers the current item's audio track and syncs the meter's tap.
    private func setMeterSource(track: AVAssetTrack?) {
        meterTrack = track
        syncAudioMeterTap()
    }

    /// True while the meter's bars can be on screen. On the phone the whole
    /// scene leaves the screen in the background; the Mac's windows can stay
    /// visible whenever the app runs.
    private var canShowMeter: Bool {
        #if os(iOS)
        return !isAppInBackground
        #else
        return true
        #endif
    }

    /// Attaches the tap once per item and captures exactly while the bars
    /// can be on screen. The mix stays attached either way: replacing it
    /// mid-play rebuilds the item's audio graph and audibly interrupts
    /// playback, so only the capture flag changes with visibility.
    private func syncAudioMeterTap() {
        guard let item = player?.currentItem else { return }
        if item.audioMix == nil, let meterTrack, let audioMix = audioMeter.makeAudioMix(for: meterTrack) {
            item.audioMix = audioMix
        }
        audioMeter.setCapturing(canShowMeter)
        if !canShowMeter {
            audioMeter.reset()
        }
    }

    // MARK: - Chapters

    /// Reads the loaded book's chapters again. The old list stays in place
    /// until the re-read succeeds.
    public func refreshChapters() async {
        guard let book else { return }
        await book.refreshChapters()
        guard self.book === book else { return }
        setChapters(book.chapters)
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
            #if os(iOS)
            // Playing again makes any pending interruption resume moot, and
            // a manual pause after this must stay paused.
            wasPlayingBeforeInterruption = false
            #endif
            if let book, !hasActiveSession {
                hasActiveSession = true
                book.recordPlaybackStart()
                reportSessionStarted(for: book)
            }
            startProgressReports()
        } else {
            reanchorFromPlayer()
            audioMeter.reset()
            // The timer stops with playback: one final report below carries
            // the settled position, and a still position gives the server
            // nothing new after that.
            stopProgressReports()
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
        requestedSeconds = target
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
        } else {
            // No timer runs while paused, so a paused seek reports its new
            // position itself.
            reportProgressNow()
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
        anchor = PlaybackAnchor(positionSeconds: position, date: Date(), rate: rate, requestedSeconds: requestedSeconds)
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
            bookTitle: book?.mainTitle,
            author: book?.author,
            chapterTitle: currentChapter?.mainTitle,
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
            let message = item.error?.localizedDescription ?? String(localized: "Playback failed.")
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

    /// Observes the item's mid-play trouble signals: the failure that ends
    /// playback, the transient stall, and the stream's error log. Without
    /// these a dying item looks like a spontaneous pause.
    private func observePlaybackTrouble(of item: AVPlayerItem) {
        observePlaybackFailureToEnd(of: item)
        observeStall(of: item)
        observeErrorLog(of: item)
    }

    /// The item cannot continue: the error surfaces with the Retry button.
    /// The message is read on the posting thread; a Notification cannot
    /// cross to the main actor.
    private func observePlaybackFailureToEnd(of item: AVPlayerItem) {
        playbackFailedToEndObserver = NotificationCenter.default.addObserver(
            forName: AVPlayerItem.failedToPlayToEndTimeNotification,
            object: item,
            queue: nil
        ) { [weak self] notification in
            let error = notification.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? Error
            let message = error?.localizedDescription ?? String(localized: "Playback failed.")
            Task { @MainActor in
                self?.handleMidPlaybackFailure(message)
            }
        }
    }

    /// A stall is transient rebuffering the player recovers from itself, so
    /// it is only logged.
    private func observeStall(of item: AVPlayerItem) {
        stallObserver = observeMediaNotification(AVPlayerItem.playbackStalledNotification, from: item) { player in
            Log.playback.warning("Playback stalled at \(player.currentTime, format: .fixed(precision: 1))s")
        }
    }

    /// Streaming errors the player absorbs, such as failed range requests,
    /// land in the item's error log; each new entry is logged.
    private func observeErrorLog(of item: AVPlayerItem) {
        errorLogObserver = observeMediaNotification(AVPlayerItem.newErrorLogEntryNotification, from: item) { player in
            guard let event = player.player?.currentItem?.errorLog()?.events.last else { return }
            Log.playback.warning("Stream error at \(player.currentTime, format: .fixed(precision: 1))s: status \(event.errorStatusCode), domain \(event.errorDomain, privacy: .public), comment \(event.errorComment ?? "none", privacy: .public)")
        }
    }

    /// A failure after playback started. The position is recorded first, so
    /// the Retry button resumes where the failure hit.
    private func handleMidPlaybackFailure(_ message: String) {
        book?.recordSettledPosition(currentTime)
        handlePlaybackFailure(message)
    }

    private func removeObservers() {
        removeChapterBoundaryObserver()
        timeControlObservation?.invalidate()
        timeControlObservation = nil
        removeItemObservers()
    }

    /// Removes the observers tied to the current player item. An item swap
    /// removes only these; the player-level observers stay in place.
    private func removeItemObservers() {
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
        for observer in [playbackFailedToEndObserver, stallObserver, errorLogObserver].compactMap({ $0 }) {
            NotificationCenter.default.removeObserver(observer)
        }
        playbackFailedToEndObserver = nil
        stallObserver = nil
        errorLogObserver = nil
    }

    private func handlePlaybackFailure(_ message: String) {
        guard playbackErrorMessage == nil else { return }
        Log.playback.error("Playback failed at \(self.currentTime, format: .fixed(precision: 1))s: \(message, privacy: .public)")
        playbackErrorMessage = message
        updatePlayingState(false)
        isReady = false
        removeObservers()
        // See closeCurrentBook: the tap must detach before the item goes away.
        player?.currentItem?.audioMix = nil
        meterTrack = nil
        player = nil
        stopProgressReports()
        syncNowPlaying()
    }

    private func handlePlaybackEnded() {
        guard let book else { return }
        Log.playback.notice("Played \(book.name, privacy: .public) to its end")
        updatePlayingState(false)
        setAnchor(position: duration, rate: 0)
        book.recordSettledPosition(duration)
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

    /// Opens the reporting session on the server, once per session.
    private func reportSessionStarted(for book: Book) {
        Task {
            await client.reportPlaybackStarted(bookID: book.id, positionSeconds: currentTime)
        }
    }

    /// Runs the periodic report. Playback starts it and pause stops it,
    /// so a paused book costs no wakeups and no requests.
    private func startProgressReports() {
        guard progressReportTimer == nil else { return }
        let timer = Timer.scheduledTimer(withTimeInterval: Self.progressReportInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.reportProgressNow()
            }
        }
        timer.tolerance = Self.progressReportTolerance
        progressReportTimer = timer
    }

    private func stopProgressReports() {
        progressReportTimer?.invalidate()
        progressReportTimer = nil
    }

    /// Publishes the position from one read: the book and the server take
    /// the same value. The two never disagree by more than one interval
    /// while the book plays.
    private func reportProgressNow() {
        guard let book, hasActiveSession else { return }
        let position = currentTime
        let paused = !isPlaying
        book.recordPosition(position)
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
                book.recordSettledPosition(position)
                self.client.reportPlaybackStoppedBlocking(bookID: book.id, positionSeconds: position)
            }
        }
    }

    #if canImport(AppKit)
    private static let terminationNotification = NSApplication.willTerminateNotification
    #else
    private static let terminationNotification = UIApplication.willTerminateNotification
    #endif

    // MARK: - Audio session interruptions (iOS)

    #if os(iOS)
    private enum AudioInterruption {
        case began
        case ended(shouldResume: Bool)
        case unknown
    }

    /// Resumes playback when a call, an alarm, or Siri ends and the system
    /// says resuming is appropriate. The system's own pause at the start of
    /// an interruption flows through the playing-state observation, so this
    /// observer only ever resumes; it never pauses.
    private func observeAudioSessionInterruptions() {
        // The values are read on the posting thread; only the parsed result
        // crosses to the main actor. See observeMediaNotification.
        interruptionObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: AVAudioSession.sharedInstance(),
            queue: nil
        ) { [weak self] notification in
            let interruption = Self.parseInterruption(notification)
            Task { @MainActor in
                self?.handleInterruption(interruption)
            }
        }
    }

    private nonisolated static func parseInterruption(_ notification: Notification) -> AudioInterruption {
        guard let rawType = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: rawType)
        else { return .unknown }
        switch type {
        case .began:
            return .began
        case .ended:
            let rawOptions = notification.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
            let options = AVAudioSession.InterruptionOptions(rawValue: rawOptions)
            return .ended(shouldResume: options.contains(.shouldResume))
        @unknown default:
            return .unknown
        }
    }

    /// Detaches the meter's tap in the background and re-attaches it on
    /// return to the foreground, so background playback renders no levels
    /// nobody can see.
    private func observeAppLifecycle() {
        let center = NotificationCenter.default
        lifecycleObservers = [
            center.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.setAppInBackground(true)
                }
            },
            center.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.setAppInBackground(false)
                }
            },
        ]
    }

    private func setAppInBackground(_ inBackground: Bool) {
        guard inBackground != isAppInBackground else { return }
        isAppInBackground = inBackground
        syncAudioMeterTap()
    }

    /// Resumes only playback that the interruption itself cut off. Playback
    /// the listener started or stopped mid-interruption stands: starting
    /// clears the flag (see updatePlayingState), so a later manual pause
    /// stays paused, and playback already running is not touched.
    private func handleInterruption(_ interruption: AudioInterruption) {
        switch interruption {
        case .began:
            wasPlayingBeforeInterruption = isPlaying
        case .ended(let shouldResume):
            if shouldResume && wasPlayingBeforeInterruption && !isPlaying {
                play()
            }
            wasPlayingBeforeInterruption = false
        case .unknown:
            break
        }
    }
    #endif
}
