import SwiftUI

/// Detail view: cover, transport controls, seek bar, and the chapter list.
/// The parts that change on every time tick live in SeekBarView, so this view
/// only re-renders when the book, chapter list, or current chapter changes.
struct PlayerView: View {
    let player: PlayerController
    let imageURL: URL

    var body: some View {
        VStack(spacing: 16) {
            header
            if let message = player.playbackErrorMessage {
                errorBanner(message)
            }
            SeekBarView(player: player)
            TransportControlsView(player: player)
            Divider()
            chapterList
        }
        .padding(20)
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 16) {
            BookCoverImage(bookID: player.book?.id ?? "", url: imageURL, contentMode: .fit)
                .frame(width: 140, height: 140)
                .clipShape(RoundedRectangle(cornerRadius: 10))

            VStack(alignment: .leading, spacing: 6) {
                Text(player.book?.name ?? "")
                    .font(.title2.bold())
                if let author = player.book?.author {
                    Text(author)
                }
                if let narrator = player.book?.narrator {
                    Text("Narrated by \(narrator)")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            Spacer()
        }
        .frame(height: 140)
    }

    private func errorBanner(_ message: String) -> some View {
        HStack {
            Label(message, systemImage: "exclamationmark.triangle")
                .foregroundStyle(.red)
            Spacer()
            Button("Retry") {
                player.retryCurrentBook()
            }
        }
    }

    private var chapterList: some View {
        List(player.chapters) { chapter in
            ChapterRow(
                chapter: chapter,
                isCurrent: chapter.index == player.currentChapterIndex
            )
            .contentShape(Rectangle())
            .onTapGesture {
                Task { await player.jump(to: chapter) }
            }
        }
        .listStyle(.inset)
        .overlay {
            if player.chapters.isEmpty {
                Text("No chapters in this file")
                    .foregroundStyle(.secondary)
            }
        }
    }
}

/// The seek slider and time readout. This is the only view that reads
/// the playback time, so 30 Hz updates re-render just this subtree.
struct SeekBarView: View {
    let player: PlayerController

    @State private var sliderPosition: Double = 0
    @State private var isDraggingSlider = false

    var body: some View {
        VStack(spacing: 4) {
            slider
                .disabled(!player.isReady)
            HStack {
                if let chapter = player.currentChapter {
                    Text(chapter.title)
                        .font(.callout.weight(.medium))
                        .lineLimit(1)
                }
                Spacer()
                Text(timeText)
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var slider: some View {
        let range = player.seekRange
        return Slider(
            value: Binding(
                get: {
                    let position = isDraggingSlider ? sliderPosition : player.currentTime
                    return min(max(position, range.lowerBound), range.upperBound)
                },
                set: { sliderPosition = $0 }
            ),
            in: range
        ) { editing in
            if editing {
                isDraggingSlider = true
            } else {
                // Keep showing the drag position until the seek lands, so the bar
                // does not flash back to the pre-seek time.
                Task {
                    await player.seek(to: sliderPosition)
                    isDraggingSlider = false
                }
            }
        }
    }

    /// Elapsed and total time within the current chapter, or within the book when there are no chapters.
    private var timeText: String {
        guard let chapter = player.currentChapter else {
            return "\(formatTime(player.currentTime)) / \(formatTime(player.duration))"
        }
        let elapsed = max(0, player.currentTime - chapter.startSeconds)
        return "\(formatTime(elapsed)) / \(formatTime(chapter.durationSeconds))"
    }
}

/// Play/pause, skip buttons, and the playback speed menu.
struct TransportControlsView: View {
    let player: PlayerController

    private static let speeds: [Double] = [0.75, 1.0, 1.25, 1.5, 1.75, 2.0]

    var body: some View {
        ZStack {
            HStack(spacing: 24) {
                Button {
                    Task { await player.previousChapter() }
                } label: {
                    Image(systemName: "backward.fill").font(.title3)
                }

                Button {
                    Task { await player.skip(by: -30) }
                } label: {
                    Image(systemName: "gobackward.30").font(.title2)
                }

                Button {
                    player.togglePlayback()
                } label: {
                    Image(systemName: player.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                        .font(.system(size: 44))
                }

                Button {
                    Task { await player.skip(by: 30) }
                } label: {
                    Image(systemName: "goforward.30").font(.title2)
                }

                Button {
                    Task { await player.nextChapter() }
                } label: {
                    Image(systemName: "forward.fill").font(.title3)
                }
            }

            HStack {
                Spacer()
                speedMenu
            }
        }
        .buttonStyle(.plain)
        .disabled(!player.isReady)
        .opacity(player.isReady ? 1 : 0.4)
    }

    private var speedMenu: some View {
        Menu {
            Picker("Speed", selection: Binding(
                get: { player.playbackSpeed },
                set: { player.setPlaybackSpeed($0) }
            )) {
                ForEach(Self.speeds, id: \.self) { speed in
                    Text(speedLabel(speed)).tag(speed)
                }
            }
            .pickerStyle(.inline)
        } label: {
            Text(speedLabel(player.playbackSpeed))
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    private func speedLabel(_ speed: Double) -> String {
        String(format: "%g×", speed)
    }
}

struct ChapterRow: View {
    let chapter: Chapter
    let isCurrent: Bool

    var body: some View {
        HStack {
            Image(systemName: isCurrent ? "play.fill" : "circle")
                .font(.caption)
                .foregroundStyle(isCurrent ? Color.accentColor : .secondary)
                .frame(width: 16)
            Text(chapter.title)
                .fontWeight(isCurrent ? .semibold : .regular)
            Spacer()
            Text(formatTime(chapter.durationSeconds))
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }
}
