import SwiftUI

extension EnvironmentValues {
    /// The book position under the pointer while the user scrubs the seek
    /// bar, so readouts near the bar can track the pointer. Nil otherwise.
    @Entry var scrubPosition: Double?
}

/// Shows the listening time left in the book at the current speed. The
/// speed-adjusted readout advances one displayed second per wall second,
/// so a one-second timeline covers every speed. While the user scrubs, it
/// shows the time left from the scrub position instead.
public struct RemainingTimeView: View {
    @Environment(PlayerController.self) private var player
    @Environment(\.scrubPosition) private var scrubPosition

    public init() {}

    public var body: some View {
        // Inherits the font from its context, so it always matches the
        // total length displayed beside it.
        TimelineView(.periodic(from: .now, by: 1.0)) { context in
            Text("\(text(at: context.date)) remaining")
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
    }

    /// The listening time left at the current speed. The speed itself is not
    /// repeated here; the transport controls already show it.
    private func text(at date: Date) -> String {
        let position = scrubPosition ?? player.projectedTime(at: date)
        let remaining = max(0, player.duration - position) / player.playbackSpeed
        return formatHoursMinutes(remaining)
    }
}

/// The playback speed as a menu of the preset speeds.
struct PlaybackSpeedMenu: View {
    /// Font override for the player screen; the playback bar's readout
    /// font otherwise.
    var font: Font?

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
                .font(font ?? metrics.transport.readoutFont)
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

/// The seek bar over its times row — the elapsed and remaining times at the
/// ends, with the caller's content centered between them — scoped to the
/// current chapter, or to the book when there are no chapters. The bar's
/// motion is a Core Animation animation projected from the position anchor,
/// and the readouts tick once per displayed second, so playback drives no
/// frequent view updates.
struct SeekTimeRow<BelowCenter: View>: View {
    /// Sizes override for the player screen; the playback bar's metrics
    /// otherwise.
    var sizes: TransportMetrics?
    /// Content centered in the time-labels row under the bar.
    private let belowCenter: BelowCenter

    @Environment(PlayerController.self) private var player
    @Environment(\.layoutMetrics) private var metrics

    /// The fraction under the pointer during a scrub. Stays set until the
    /// seek lands, so the bar does not flash back to the pre-seek time.
    @State private var dragFraction: Double?

    /// How the current drag maps the pointer to a fraction. Nil between drags.
    @State private var scrubOrigin: ScrubOrigin?

    init(sizes: TransportMetrics? = nil, @ViewBuilder belowCenter: () -> BelowCenter) {
        self.sizes = sizes
        self.belowCenter = belowCenter()
    }

    var body: some View {
        VStack(spacing: 6) {
            seekBar
                .opacity(player.isReady ? 1 : 0.4)
            timesRow
                .overlay {
                    belowCenter
                        .environment(\.scrubPosition, scrubPosition)
                }
        }
    }

    private var readoutFont: Font {
        (sizes ?? metrics.transport).readoutFont
    }

    private var timesRow: some View {
        TimelineView(.periodic(from: .now, by: tickInterval)) { context in
            let elapsed = scopeElapsed(at: context.date)
            HStack {
                Text(formatElapsedTime(elapsed.seconds, matching: elapsed.total))
                Spacer()
                Text(remainingText(elapsed))
            }
        }
        .font(readoutFont)
        .foregroundStyle(.secondary)
    }

    private var seekBar: some View {
        GeometryReader { geometry in
            AnimatedProgressBar(anchor: barAnchor, isScrubbing: dragFraction != nil)
                .allowsHitTesting(false)
                .overlay {
                    Color.clear
                        .contentShape(Rectangle())
                        .gesture(scrubGesture(width: geometry.size.width))
                }
        }
        .frame(height: seekBarHeight)
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
                let origin = scrubOrigin ?? scrubOrigin(for: value, width: width)
                scrubOrigin = origin
                dragFraction = scrubFraction(for: value, origin: origin, width: width)
            }
            .onEnded { value in
                guard player.isReady else { return }
                let origin = scrubOrigin ?? scrubOrigin(for: value, width: width)
                scrubOrigin = nil
                guard !isStationaryKnobGrab(value, origin: origin) else {
                    dragFraction = nil
                    return
                }
                seek(toFraction: scrubFraction(for: value, origin: origin, width: width))
            }
    }

    /// Decides whether a drag grabs the knob or presses the track, from where
    /// the pointer went down relative to the knob.
    private func scrubOrigin(for value: DragGesture.Value, width: CGFloat) -> ScrubOrigin {
        let knobFraction = projectedBarFraction(at: Date())
        let knobX = knobFraction * width
        let radius = AnimatedProgressBar.knobDiameter / 2
        if abs(value.startLocation.x - knobX) <= radius {
            return .knob(startFraction: knobFraction)
        }
        return .track
    }

    /// The fraction the pointer maps to: the knob's start fraction plus the
    /// pointer's travel for a knob grab, the pointer's position for a press.
    private func scrubFraction(for value: DragGesture.Value, origin: ScrubOrigin, width: CGFloat) -> Double {
        switch origin {
        case .knob(let startFraction):
            return clampFraction(startFraction + value.translation.width / max(width, 1))
        case .track:
            return fraction(at: value.location.x, width: width)
        }
    }

    /// True when the user pressed the knob and released without moving it.
    private func isStationaryKnobGrab(_ value: DragGesture.Value, origin: ScrubOrigin) -> Bool {
        guard case .knob = origin else { return false }
        return value.translation.width == 0
    }

    /// The bar's displayed fraction at a date, projected from its anchor.
    private func projectedBarFraction(at date: Date) -> Double {
        let anchor = barAnchor
        let elapsed = max(0, date.timeIntervalSince(anchor.date))
        return clampFraction(anchor.fraction + anchor.fractionsPerSecond * elapsed)
    }

    private func seek(toFraction fraction: Double) {
        let range = player.seekRange
        let target = range.lowerBound + fraction * (range.upperBound - range.lowerBound)
        Task {
            await player.seek(to: target)
            dragFraction = nil
        }
    }

    private func fraction(at x: CGFloat, width: CGFloat) -> Double {
        clampFraction(x / max(width, 1))
    }

    private func clampFraction(_ fraction: Double) -> Double {
        min(1, max(0, fraction))
    }

    /// One tick per displayed second: the readouts cross second boundaries
    /// at the playback speed. Reading the speed keeps it observed.
    private var tickInterval: TimeInterval {
        1.0 / max(player.playbackSpeed, 0.25)
    }

    /// The elapsed time within the seek scope, with the scope's total.
    private func scopeElapsed(at date: Date) -> (seconds: Double, total: Double) {
        let position = displayedPosition(at: date)
        guard let chapter = player.currentChapter else {
            return (max(0, min(position, player.duration)), player.duration)
        }
        let elapsed = max(0, min(position, chapter.endSeconds) - chapter.startSeconds)
        return (elapsed, chapter.durationSeconds)
    }

    /// The time left in the seek scope, with a leading minus sign.
    private func remainingText(_ elapsed: (seconds: Double, total: Double)) -> String {
        "-" + formatElapsedTime(max(0, elapsed.total - elapsed.seconds), matching: elapsed.total)
    }

    /// The position the elapsed text shows: the scrub target while dragging,
    /// so the readout tracks the pointer, and the playback position otherwise.
    private func displayedPosition(at date: Date) -> Double {
        scrubPosition ?? player.projectedTime(at: date)
    }

    /// The book position under the pointer while dragging. Nil otherwise.
    private var scrubPosition: Double? {
        guard let dragFraction else { return nil }
        let range = player.seekRange
        return range.lowerBound + dragFraction * (range.upperBound - range.lowerBound)
    }
}

/// Height of the seek bar's hit area.
private let seekBarHeight: CGFloat = 18

/// How a drag on the seek bar maps the pointer to a fraction. A knob grab
/// moves the knob by the pointer's travel from where the knob sat. A track
/// press puts the knob under the pointer.
private enum ScrubOrigin {
    case knob(startFraction: Double)
    case track
}

/// Which buttons a transport cluster shows.
public enum TransportLayout {
    /// Skip back, the play button at its own size, and skip forward.
    case full
    /// The play button at the skip buttons' size, then skip forward.
    case brief

    var showsSkipBack: Bool {
        self == .full
    }
}

/// The skip and play/pause buttons, driving the loaded book. The skips
/// come from the shared transport skips.
struct TransportControlsView: View {
    var layout: TransportLayout = .full
    /// Sizes override for the player screen; the playback bar's metrics
    /// otherwise.
    var sizes: TransportMetrics?

    @Environment(PlayerController.self) private var player
    @Environment(\.layoutMetrics) private var metrics

    private var resolvedSizes: TransportMetrics {
        sizes ?? metrics.transport
    }

    var body: some View {
        HStack(spacing: resolvedSizes.buttonSpacing) {
            if layout.showsSkipBack {
                SkipButton(skip: .back, size: resolvedSizes.skipButtonSize)
            }
            playPauseButton
            SkipButton(skip: .forward, size: resolvedSizes.skipButtonSize)
        }
        .disabled(!player.isReady)
        .opacity(player.isReady ? 1 : 0.4)
    }

    private var playPauseButton: some View {
        Button {
            player.togglePlayback()
        } label: {
            playPauseGlyph
                .contentTransition(.symbolEffect(.replace, options: .speed(2)))
        }
        .buttonStyle(HoverDimButtonStyle())
    }

    /// The play and pause glyphs differ in width, so a fixed frame keeps
    /// the skip buttons still when the glyph swaps.
    private var playPauseGlyph: some View {
        Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
            .font(.system(size: playGlyphSize))
            .frame(width: playGlyphSize)
    }

    private var playGlyphSize: CGFloat {
        switch layout {
        case .full: return resolvedSizes.playButtonSize
        case .brief: return resolvedSizes.skipButtonSize
        }
    }
}

/// One skip button, whose arrow turns once for each skip in its direction,
/// wherever the skip came from.
private struct SkipButton: View {
    let skip: TransportSkip
    let size: CGFloat

    @Environment(PlayerController.self) private var player

    /// The stored interval, read so a change of it in the settings redraws
    /// the numbered symbol.
    @AppStorage private var intervalSeconds: Double

    init(skip: TransportSkip, size: CGFloat) {
        self.skip = skip
        self.size = size
        _intervalSeconds = AppStorage(wrappedValue: SkipIntervals.defaultSeconds, skip.storageKey)
    }

    var body: some View {
        Button {
            skip.perform(on: player)
        } label: {
            Image(systemName: skip.symbolName)
                .font(.system(size: size))
                .symbolEffect(.rotate, options: .nonRepeating.speed(2), value: player.skipCounts[skip, default: 0])
        }
        .buttonStyle(HoverDimButtonStyle())
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
