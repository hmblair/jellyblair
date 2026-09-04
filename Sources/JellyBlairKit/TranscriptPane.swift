import SwiftUI

/// The transcript with its own floating search bar and tracking button.
/// The search state and the tracking flag are pane-local; the coordinator
/// behind the controller does the matching, painting, and centering.
struct TranscriptPane: View {
    let book: Book
    let model: BookModel
    let chapters: [Chapter]
    let isLoaded: Bool
    let canStartPlayback: Bool
    /// The pane stays alive while hidden so the transcript keeps tracking
    /// the narration, and switching to it opens on the current word.
    let isVisible: Bool

    @Environment(PlayerController.self) private var player

    @State private var query = ""
    /// Whether the transcript follows the spoken word. On by default;
    /// scrolling by hand or jumping to a search match turns it off.
    @State private var isTracking = true
    /// The handle the pane centers and searches the transcript through.
    @State private var controller = TranscriptController()

    /// The search phrase, without surrounding whitespace.
    private var trimmedQuery: String {
        query.trimmingCharacters(in: .whitespaces)
    }

    var body: some View {
        transcript
            .floatingSearchBar {
                searchField
                trackingButton
            }
            // The screen stays awake while the playing transcript follows
            // the narration; a paused or previewed book lets it sleep, since
            // its transcript does not move.
            .keepsScreenAwake(
                isVisible && isTracking && isLoaded && player.isPlaying,
                reason: "The transcript follows the narration"
            )
    }

    /// The transcript, marked at the listener's position. The timeline fires
    /// exactly when playback reaches each word, projected through the playback
    /// anchor, so the word mark lands on the boundaries without a fast timer.
    /// The anchor moves on every playback event, rebuilding the schedule.
    private var transcript: some View {
        let lines = model.lyrics
        let chapters = chapters
        return TimelineView(tickSchedule) { context in
            transcriptText(at: listeningPosition(at: context.date), lines: lines, chapters: chapters)
        }
        .task(id: book.id) {
            await model.fetchLyricsIfNeeded()
        }
    }

    /// The transcript's redraw schedule, rebuilt whenever the anchor moves.
    /// Reading the anchor and playing state here keeps them observed, so a
    /// playback event re-evaluates the body and replaces the schedule.
    private var tickSchedule: TranscriptTickSchedule {
        TranscriptTickSchedule(
            tickSeconds: model.transcriptTickSeconds,
            anchor: player.anchor,
            isRunning: isLoaded && player.isPlaying
        )
    }

    private func transcriptText(at positionSeconds: Double, lines: [LyricLine], chapters: [Chapter]) -> some View {
        TranscriptTextView(
            lines: lines,
            chapters: chapters,
            positionSeconds: positionSeconds,
            isTracking: isTracking,
            isVisible: isVisible,
            searchQuery: trimmedQuery,
            topInset: floatingBarZoneHeight + 6,
            bottomInset: PaneLayout.bottomRestingInset,
            horizontalPadding: PaneLayout.transcriptHorizontalPadding,
            controller: controller,
            onWordTap: { cue in
                jump(toSeconds: cue.startSeconds)
            },
            onUserScroll: {
                isTracking = false
            }
        )
        .overlay {
            if model.lyrics.isEmpty {
                if model.isFetchingLyrics {
                    ProgressView()
                } else {
                    Text("No transcript for this book")
                        .foregroundStyle(.secondary)
                }
            } else if controller.isPreparingLayout {
                ProgressView()
            }
        }
    }

    /// The listener's position: the playing position when loaded, or the
    /// resume position in a preview.
    private func listeningPosition(at date: Date) -> Double {
        isLoaded ? player.projectedTime(at: date) : model.resumePositionSeconds
    }

    /// Seeks a loaded book to the position, or starts playback there in a preview.
    private func jump(toSeconds seconds: Double) {
        if isLoaded {
            Task { await player.jump(toSeconds: seconds) }
        } else if canStartPlayback {
            player.open(model, playWhenReady: true, startAtSeconds: seconds)
        }
    }

    // MARK: - Search

    private var searchField: some View {
        CapsuleSearchField("Search Transcript", text: $query) {
            if !trimmedQuery.isEmpty {
                MatchNavigator(count: controller.matchCount, index: controller.matchIndex, isSearching: controller.isSearching) { delta in
                    controller.stepMatch(by: delta)
                }
            }
        }
        .onSubmit {
            controller.stepMatch(by: 1)
        }
        // Shift-return steps backward; plain return falls through to onSubmit.
        .onKeyPress(keys: [.return]) { press in
            guard press.modifiers.contains(.shift) else { return .ignored }
            controller.stepMatch(by: -1)
            return .handled
        }
    }

    // MARK: - Tracking

    /// Toggles following the spoken word. Turning it on centers right away.
    private var trackingButton: some View {
        CapsuleIconButton(
            "scope",
            isOn: isTracking,
            help: isTracking ? "Stop following the listening position" : "Follow the listening position"
        ) {
            isTracking.toggle()
            guard isTracking else { return }
            controller.centerOnSpokenWord(animated: true)
        }
    }
}

/// Fires at each transcript tick moment, projected through the playback
/// anchor, with a few milliseconds of slack placing each redraw just past
/// its boundary so the projected position always covers the word. Entries
/// generate lazily on demand, so replacing the schedule after an anchor
/// change allocates nothing per remaining cue. Empty while nothing moves,
/// so a paused transcript never redraws.
private struct TranscriptTickSchedule: TimelineSchedule {
    /// The tick moments as positions, sorted without duplicates.
    let tickSeconds: [Double]
    let anchor: PlaybackAnchor
    let isRunning: Bool

    /// Delay after each boundary, keeping the redraw just past it.
    private static let slack: TimeInterval = 0.005

    func entries(from startDate: Date, mode: TimelineScheduleMode) -> AnySequence<Date> {
        guard isRunning, anchor.rate > 0 else { return AnySequence([]) }
        let anchor = anchor
        let position = anchor.position(at: startDate)
        let upcoming = tickSeconds[firstIndex(after: position)...]
        return AnySequence(upcoming.lazy.compactMap { seconds in
            anchor.date(forPosition: seconds)?.addingTimeInterval(Self.slack)
        })
    }

    /// The index of the first tick strictly past the position, found by
    /// binary search.
    private func firstIndex(after position: Double) -> Int {
        var low = 0
        var high = tickSeconds.count
        while low < high {
            let mid = (low + high) / 2
            if tickSeconds[mid] <= position {
                low = mid + 1
            } else {
                high = mid
            }
        }
        return low
    }
}
