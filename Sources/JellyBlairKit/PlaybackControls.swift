import SwiftUI

/// Shows the listening time left in the book at the current speed. The
/// speed-adjusted readout advances one displayed second per wall second,
/// so a one-second timeline covers every speed.
public struct RemainingTimeView: View {
    @Environment(PlayerController.self) private var player

    public init() {}

    public var body: some View {
        // Inherits the font from its context, so it always matches the
        // total length displayed beside it.
        TimelineView(.periodic(from: .now, by: 1.0)) { context in
            Text(text(at: context.date))
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
    }

    /// The listening time left at the current speed. The speed itself is not
    /// repeated here; the transport controls already show it.
    private func text(at date: Date) -> String {
        let remaining = max(0, player.duration - player.projectedTime(at: date)) / player.playbackSpeed
        return formatHoursMinutes(remaining)
    }
}

/// The playback speed as a menu of the preset speeds.
struct PlaybackSpeedMenu: View {
    @Environment(PlayerController.self) private var player
    @Environment(\.layoutMetrics) private var metrics

    @State private var isHovering = false

    private static let speeds: [Double] = [0.75, 1.0, 1.25, 1.5, 1.75, 2.0]

    var body: some View {
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
                .font(metrics.transport.readoutFont)
                .foregroundStyle(.secondary)
        }
        .fixedSize()
        .menuIndicator(.hidden)
        // The label uses the time display's gray instead of the tint.
        .tint(Color.secondary)
        .buttonStyle(.plain)
        .menuStyle(.borderlessButton)
        .padding(4)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.primary.opacity(isHovering ? 0.1 : 0))
        )
        .onHover { isHovering = $0 }
        .animation(.easeOut(duration: 0.1), value: isHovering)
    }
}

/// The seek bar flanked by the elapsed and total time, scoped to the
/// current chapter, or to the book when there are no chapters. The bar's
/// motion is a Core Animation animation projected from the position anchor,
/// and the elapsed readout ticks once per displayed second, so playback
/// drives no frequent view updates.
struct SeekTimeRow: View {
    @Environment(PlayerController.self) private var player
    @Environment(\.layoutMetrics) private var metrics

    /// The fraction under the pointer during a scrub. Stays set until the
    /// seek lands, so the bar does not flash back to the pre-seek time.
    @State private var dragFraction: Double?

    var body: some View {
        HStack(spacing: 8) {
            TimelineView(.periodic(from: .now, by: tickInterval)) { context in
                Text(elapsedText(at: context.date))
            }
            .font(metrics.transport.readoutFont)
            .foregroundStyle(.secondary)
            seekBar
                .opacity(player.isReady ? 1 : 0.4)
            Text(totalText)
                .font(metrics.transport.readoutFont)
                .foregroundStyle(.secondary)
        }
    }

    private var seekBar: some View {
        GeometryReader { geometry in
            AnimatedProgressBar(anchor: barAnchor)
                .allowsHitTesting(false)
                .overlay {
                    Color.clear
                        .contentShape(Rectangle())
                        .gesture(scrubGesture(width: geometry.size.width))
                }
        }
        .frame(height: 18)
    }

    /// The bar's anchor in chapter-fraction space: the scrub position while
    /// dragging, the player's position anchor otherwise.
    private var barAnchor: ProgressAnchor {
        if let dragFraction {
            return ProgressAnchor(fraction: dragFraction, fractionsPerSecond: 0, date: .distantPast)
        }
        let range = player.seekRange
        let span = max(range.upperBound - range.lowerBound, 0.001)
        let anchor = player.anchor
        // The anchor can date from before this chapter, leaving the fraction
        // negative. It must pass unclamped: the bar clamps only the projected
        // value, so the projection still lands on the true position.
        let fraction = (anchor.positionSeconds - range.lowerBound) / span
        return ProgressAnchor(
            fraction: fraction,
            fractionsPerSecond: anchor.rate / span,
            date: anchor.date
        )
    }

    private func scrubGesture(width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                guard player.isReady else { return }
                dragFraction = fraction(at: value.location.x, width: width)
            }
            .onEnded { value in
                guard player.isReady else { return }
                let range = player.seekRange
                let target = range.lowerBound + fraction(at: value.location.x, width: width) * (range.upperBound - range.lowerBound)
                Task {
                    await player.seek(to: target)
                    dragFraction = nil
                }
            }
    }

    private func fraction(at x: CGFloat, width: CGFloat) -> Double {
        min(1, max(0, x / max(width, 1)))
    }

    /// One tick per displayed second: the elapsed readout crosses second
    /// boundaries at the playback speed. Reading the speed keeps it observed.
    private var tickInterval: TimeInterval {
        1.0 / max(player.playbackSpeed, 0.25)
    }

    /// The elapsed time within the seek scope.
    private func elapsedText(at date: Date) -> String {
        let position = displayedPosition(at: date)
        guard let chapter = player.currentChapter else {
            return formatElapsedTime(position, matching: player.duration)
        }
        let elapsed = max(0, min(position, chapter.endSeconds) - chapter.startSeconds)
        return formatElapsedTime(elapsed, matching: chapter.durationSeconds)
    }

    /// The total time of the seek scope.
    private var totalText: String {
        formatTime(player.currentChapter?.durationSeconds ?? player.duration)
    }

    /// The position the elapsed text shows: the scrub target while dragging,
    /// so the readout tracks the pointer, and the playback position otherwise.
    private func displayedPosition(at date: Date) -> Double {
        guard let dragFraction else { return player.projectedTime(at: date) }
        let range = player.seekRange
        return range.lowerBound + dragFraction * (range.upperBound - range.lowerBound)
    }
}

/// The skip and play/pause buttons. The skip amounts come from the stored
/// intervals, with the numbered arrow symbols following them. Chapter
/// navigation lives in the system Now Playing commands and the chapter
/// list.
struct TransportControlsView: View {
    @Environment(PlayerController.self) private var player
    @Environment(\.layoutMetrics) private var metrics

    @AppStorage(SkipIntervals.backKey) private var skipBackSeconds: Double = SkipIntervals.defaultSeconds
    @AppStorage(SkipIntervals.forwardKey) private var skipForwardSeconds: Double = SkipIntervals.defaultSeconds

    var body: some View {
        HStack(spacing: metrics.transport.buttonSpacing) {
            Button {
                Task { await player.skip(by: -skipBackSeconds) }
            } label: {
                Image(systemName: "gobackward.\(Int(skipBackSeconds))").font(.system(size: metrics.transport.skipButtonSize))
            }
            .buttonStyle(HoverDimButtonStyle())

            Button {
                player.togglePlayback()
            } label: {
                Image(systemName: player.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                    .font(.system(size: metrics.transport.playButtonSize))
                    .contentTransition(.identity)
                    .animation(nil, value: player.isPlaying)
            }
            .buttonStyle(HoverDimButtonStyle())

            Button {
                Task { await player.skip(by: skipForwardSeconds) }
            } label: {
                Image(systemName: "goforward.\(Int(skipForwardSeconds))").font(.system(size: metrics.transport.skipButtonSize))
            }
            .buttonStyle(HoverDimButtonStyle())
        }
        .disabled(!player.isReady)
        .opacity(player.isReady ? 1 : 0.4)
    }
}

/// Plain button that dims while the pointer hovers.
private struct HoverDimButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        HoverDimBody(configuration: configuration)
    }

    private struct HoverDimBody: View {
        let configuration: Configuration

        @State private var isHovering = false

        var body: some View {
            configuration.label
                .opacity(isHovering ? 0.6 : 1)
                .onHover { isHovering = $0 }
                .animation(.easeOut(duration: 0.1), value: isHovering)
        }
    }
}
