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
    /// behind the view projects the position from the anchor and wakes
    /// itself at each word boundary, so the view only updates on playback
    /// events, not per word. Reading the anchor here keeps it observed.
    private var transcript: some View {
        transcriptText(anchor: listeningAnchor, lines: model.lyrics, chapters: chapters)
            .task(id: book.id) {
                await model.fetchLyricsIfNeeded()
            }
    }

    /// The anchor the transcript follows: the player's while the book is
    /// loaded, or a still anchor at the resume position in a preview.
    private var listeningAnchor: PlaybackAnchor {
        isLoaded
            ? player.anchor
            : PlaybackAnchor(positionSeconds: model.resumePositionSeconds, date: .distantPast, rate: 0)
    }

    private func transcriptText(anchor: PlaybackAnchor, lines: [LyricLine], chapters: [Chapter]) -> some View {
        TranscriptTextView(
            lines: lines,
            chapters: chapters,
            anchor: anchor,
            isTracking: isTracking,
            isVisible: isVisible,
            searchQuery: query,
            searchIsCaseSensitive: isCaseSensitive,
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
