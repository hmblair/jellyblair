import SwiftUI

/// The transcript with its own floating search bar and tracking button.
/// The search state and the tracking flag are pane-local; the coordinator
/// behind the controller does the matching, painting, and centering.
struct TranscriptPane: View {
    let book: Book
    let chapters: [Chapter]
    let isLoaded: Bool
    let canStartPlayback: Bool
    /// The pane stays alive while hidden, but its transcript sleeps and
    /// catches up in one step when shown, so switching to it still opens
    /// on the current word.
    let isVisible: Bool

    @Environment(PlayerController.self) private var player
    @Environment(\.layoutMetrics) private var metrics

    /// The transcript sleeps with the scene, which on the phone includes a
    /// locked screen during background playback.
    @Environment(\.scenePhase) private var scenePhase

    @State private var query = ""
    @State private var isCaseSensitive = false
    /// Whether the transcript follows the spoken word. On by default;
    /// scrolling by hand or jumping to a search match turns it off.
    @State private var isTracking = true
    /// The handle the pane centers and searches the transcript through.
    @State private var controller = TranscriptController()

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

    /// The transcript, marked at the listener's position. The coordinator
    /// projects the position from the anchor and wakes itself at each word
    /// boundary, so the view only updates on playback events. Reading the
    /// anchor here keeps it observed.
    private var transcript: some View {
        transcriptText(anchor: listeningAnchor, lines: book.lyrics, chapters: chapters)
            .task(id: book.id) {
                await book.fetchLyricsIfNeeded()
            }
    }

    /// The anchor the transcript follows: the player's while the book is
    /// loaded, or a still anchor at the resume position in a preview.
    private var listeningAnchor: PlaybackAnchor {
        isLoaded
            ? player.anchor
            : PlaybackAnchor(positionSeconds: book.resumePositionSeconds, date: .distantPast, rate: 0, requestedSeconds: book.resumePositionSeconds)
    }

    private func transcriptText(anchor: PlaybackAnchor, lines: [LyricLine], chapters: [Chapter]) -> some View {
        TranscriptTextView(
            lines: lines,
            chapters: chapters,
            anchor: anchor,
            isTracking: isTracking,
            isVisible: isVisible,
            isSceneActive: scenePhase == .active,
            searchQuery: query,
            searchIsCaseSensitive: isCaseSensitive,
            topInset: floatingBarClearance,
            bottomInset: PaneLayout.bottomRestingInset,
            horizontalPadding: metrics.pane.transcriptHorizontalPadding,
            controller: controller,
            onWordTap: { cue in
                jump(toSeconds: cue.startSeconds)
            },
            onChapterTap: { chapter in
                jump(toSeconds: chapter.startSeconds)
            },
            onUserScroll: {
                isTracking = false
            }
        )
        .overlay {
            if book.lyrics.isEmpty {
                if book.isFetchingLyrics {
                    ProgressView()
                } else {
                    Text("No transcript for this book")
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    /// Seeks a loaded book to the position, or starts playback there in a preview.
    private func jump(toSeconds seconds: Double) {
        if isLoaded {
            Task { await player.jump(toSeconds: seconds) }
        } else if canStartPlayback {
            player.open(book, playWhenReady: true, startAtSeconds: seconds)
        }
    }

    // MARK: - Search

    private var searchField: some View {
        CapsuleSearchField("Search Transcript", text: $query) {
            if !query.isEmpty {
                MatchNavigator(isCaseSensitive: $isCaseSensitive, count: controller.matchCount, index: controller.matchIndex, isSearching: controller.isSearching) { delta in
                    controller.stepMatch(by: delta)
                }
            }
        }
        .stepsMatchesOnSubmit { delta in
            controller.stepMatch(by: delta)
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
