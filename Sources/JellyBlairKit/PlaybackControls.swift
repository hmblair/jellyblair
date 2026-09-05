import SwiftUI

/// Shows the listening time left in the book at the current speed.
/// A periodic timeline drives the text, since the position anchor itself
/// only changes on playback events. The readout is speed-adjusted time,
/// which advances one displayed second per wall second at any speed, so
/// one tick per second always covers it.
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

/// The seek bar and time readout. The bar's motion is a Core Animation
/// animation projected from the position anchor, and the time text ticks
/// once per elapsed second at the playback speed, so playback drives no
/// frequent view updates.
public struct SeekBarView: View {
    @Environment(PlayerController.self) private var player

    /// The fraction under the pointer during a scrub. Stays set until the
    /// seek lands, so the bar does not flash back to the pre-seek time.
    @State private var dragFraction: Double?

    @State private var isHoveringSpeed = false

    private static let speeds: [Double] = [0.75, 1.0, 1.25, 1.5, 1.75, 2.0]

    public init() {}

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
        .menuIndicator(.hidden)
        // The label wears the time display's gray instead of the tint.
        .tint(Color.secondary)
    }

    public var body: some View {
        VStack(spacing: 4) {
            seekBar
                .opacity(player.isReady ? 1 : 0.4)
            HStack {
                if let chapter = player.currentChapter {
                    Text(chapter.title)
                        .font(.callout.weight(.medium))
                        .lineLimit(1)
                }
                Spacer()
                speedMenu
                    .buttonStyle(.plain)
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    .padding(4)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(Color.primary.opacity(isHoveringSpeed ? 0.1 : 0))
                    )
                    .onHover { isHoveringSpeed = $0 }
                    .animation(.easeOut(duration: 0.1), value: isHoveringSpeed)
                TimelineView(.periodic(from: .now, by: tickInterval)) { context in
                    Text(timeText(at: context.date))
                        .font(.callout.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
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
        .frame(height: 16)
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

    /// One tick per displayed second: the elapsed readout advances at the
    /// playback speed, so faster speeds cross second boundaries more often.
    /// Reading the speed here keeps it observed, so a speed change replaces
    /// the schedule.
    private var tickInterval: TimeInterval {
        1.0 / max(player.playbackSpeed, 0.25)
    }

    /// Elapsed and total time within the current chapter, or within the book when there are no chapters.
    private func timeText(at date: Date) -> String {
        let position = displayedPosition(at: date)
        guard let chapter = player.currentChapter else {
            return formatTimePair(elapsed: position, total: player.duration)
        }
        let elapsed = max(0, min(position, chapter.endSeconds) - chapter.startSeconds)
        return formatTimePair(elapsed: elapsed, total: chapter.durationSeconds)
    }

    /// The position the time text shows: the scrub target while dragging,
    /// so the readout tracks the pointer, and the playback position otherwise.
    private func displayedPosition(at date: Date) -> Double {
        guard let dragFraction else { return player.projectedTime(at: date) }
        let range = player.seekRange
        return range.lowerBound + dragFraction * (range.upperBound - range.lowerBound)
    }
}

/// Play/pause, skip buttons, and chapter navigation.
public struct TransportControlsView: View {
    @Environment(PlayerController.self) private var player

    #if os(macOS)
    private static let playButtonSize: CGFloat = 44
    #else
    private static let playButtonSize: CGFloat = 55
    #endif

    public init() {}

    public var body: some View {
        HStack(spacing: 24) {
                Button {
                    Task { await player.previousChapter() }
                } label: {
                    Image(systemName: "backward.fill").font(.title3)
                }
                .buttonStyle(HoverScaleButtonStyle())

                Button {
                    Task { await player.skip(by: -30) }
                } label: {
                    Image(systemName: "gobackward.30").font(.title2)
                }
                .buttonStyle(HoverScaleButtonStyle())

                Button {
                    player.togglePlayback()
                } label: {
                    Image(systemName: player.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                        .font(.system(size: Self.playButtonSize))
                        .contentTransition(.identity)
                        .animation(nil, value: player.isPlaying)
                }
                .buttonStyle(HoverScaleButtonStyle())

                Button {
                    Task { await player.skip(by: 30) }
                } label: {
                    Image(systemName: "goforward.30").font(.title2)
                }
                .buttonStyle(HoverScaleButtonStyle())

                Button {
                    Task { await player.nextChapter() }
                } label: {
                    Image(systemName: "forward.fill").font(.title3)
                }
                .buttonStyle(HoverScaleButtonStyle())
        }
        .frame(maxWidth: .infinity)
        .disabled(!player.isReady)
        .opacity(player.isReady ? 1 : 0.4)
    }
}

/// Plain button that grows slightly while the pointer hovers.
private struct HoverScaleButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        HoverScaleBody(configuration: configuration)
    }

    private struct HoverScaleBody: View {
        let configuration: Configuration

        @State private var isHovering = false

        var body: some View {
            configuration.label
                .scaleEffect(isHovering ? 1.08 : 1)
                .onHover { isHovering = $0 }
                .animation(.easeOut(duration: 0.12), value: isHovering)
        }
    }
}
