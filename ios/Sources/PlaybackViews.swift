import JellyBlairKit
import SwiftUI

/// Shows the listening time left in the book at the current speed.
/// Minute granularity keeps the label stable between time ticks.
struct RemainingTimeView: View {
    let player: PlayerController

    var body: some View {
        Text(text)
            .font(.footnote.monospacedDigit())
            .foregroundStyle(.secondary)
    }

    private var text: String {
        let remaining = max(0, player.duration - player.currentTime) / player.playbackSpeed
        let minutes = Int((remaining / 60).rounded())
        let label = minutes >= 60 ? "\(minutes / 60)h \(minutes % 60)m" : "\(minutes)m"
        guard player.playbackSpeed != 1 else {
            return "\(label) remaining"
        }
        return "\(label) remaining at \(formatPlaybackSpeed(player.playbackSpeed))"
    }
}

/// The seek slider and time readout. This is the only view that reads
/// the playback time, so frequent updates re-render just this subtree.
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

/// Play/pause, skip buttons, chapter navigation, and the playback speed menu.
struct TransportControlsView: View {
    let player: PlayerController

    private static let speeds: [Double] = [0.75, 1.0, 1.25, 1.5, 1.75, 2.0]

    var body: some View {
        ZStack {
            HStack(spacing: 22) {
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
                    Text(formatPlaybackSpeed(speed)).tag(speed)
                }
            }
            .pickerStyle(.inline)
        } label: {
            Text(formatPlaybackSpeed(player.playbackSpeed))
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .fixedSize()
    }
}

enum ChapterRowState {
    case played
    case current
    case upcoming
}

struct ChapterRow: View {
    let chapter: Chapter
    let state: ChapterRowState
    let isPlaying: Bool
    let meter: AudioLevelMeter

    var body: some View {
        HStack {
            icon
                .frame(width: 16)
            Text(chapter.title)
                .fontWeight(state == .current ? .semibold : .regular)
                .foregroundStyle(state == .played ? .secondary : .primary)
            Spacer()
            Text(formatTime(chapter.durationSeconds))
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private var icon: some View {
        switch state {
        case .played:
            Image(systemName: "checkmark")
                .font(.caption)
                .foregroundStyle(.tertiary)
        case .current:
            AudioBarsView(meter: meter, isPlaying: isPlaying)
        case .upcoming:
            Color.clear
        }
    }
}

/// Bars driven by the live band levels of the playing audio.
struct AudioBarsView: View {
    let meter: AudioLevelMeter
    let isPlaying: Bool

    private static let barMaxHeight: CGFloat = 11
    private static let barMinHeight: CGFloat = 2

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: !isPlaying)) { _ in
            let bands = meter.currentBands()
            HStack(alignment: .bottom, spacing: 1.5) {
                ForEach(0..<AudioLevelMeter.bandCount, id: \.self) { index in
                    Capsule()
                        .fill(Color.accentColor)
                        .frame(width: 2, height: Self.barMinHeight + CGFloat(bands[index]) * (Self.barMaxHeight - Self.barMinHeight))
                }
            }
            .frame(height: Self.barMaxHeight, alignment: .bottom)
        }
    }
}
