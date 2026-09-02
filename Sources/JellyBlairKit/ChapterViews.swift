import SwiftUI

/// A chapter row's relationship to the listener's position.
public enum ChapterRowState: Equatable {
    /// How to mark the current chapter.
    public enum CurrentMarker: Equatable {
        /// The loaded book is audibly playing here: live level bars.
        case playing
        /// The loaded book is paused here: flat level bars.
        case paused
        /// A preview of another book resumes here: a bookmark.
        case bookmark
    }

    case played
    case current(CurrentMarker)
    case upcoming
}

public struct ChapterRow: View {
    let chapter: Chapter
    let state: ChapterRowState
    let meter: AudioLevelMeter

    public init(chapter: Chapter, state: ChapterRowState, meter: AudioLevelMeter) {
        self.chapter = chapter
        self.state = state
        self.meter = meter
    }

    private var isCurrent: Bool {
        if case .current = state { return true }
        return false
    }

    @State private var isHovering = false

    public var body: some View {
        HStack {
            icon
                .frame(width: 16)
            Text(chapter.title)
                .fontWeight(isCurrent ? .semibold : .regular)
                .foregroundStyle(state == .played ? .secondary : .primary)
            Spacer()
            Text(formatTime(chapter.durationSeconds))
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 8)
        // The highlight bounds to the visible content: it skips the icon
        // column when the row has no mark, and cannot overhang the list edges
        // the way a full row background does.
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.primary.opacity(0.06))
                .opacity(isHovering ? 1 : 0)
                .animation(.easeOut(duration: 0.1), value: isHovering)
                .padding(.leading, state == .upcoming ? 24 : 0)
                .padding(.trailing, -9)
        )
        .onHover { isHovering = $0 }
        .listRowInsets(EdgeInsets(top: 0, leading: 4, bottom: 0, trailing: 4))
    }

    @ViewBuilder
    private var icon: some View {
        switch state {
        case .played:
            Image(systemName: "checkmark")
                .font(.caption)
                .foregroundStyle(.tertiary)
        case .current(.playing):
            AudioBarsView(meter: meter, isPlaying: true)
        case .current(.paused):
            AudioBarsView(meter: meter, isPlaying: false)
        case .current(.bookmark):
            Image(systemName: "bookmark.fill")
                .font(.caption)
                .foregroundStyle(Color.accentColor)
        case .upcoming:
            Color.clear
        }
    }
}

/// Bars driven by the live band levels of the playing audio.
public struct AudioBarsView: View {
    let meter: AudioLevelMeter
    let isPlaying: Bool

    /// Increased inside a selected list row, in sync with the accent pill,
    /// so the bars whiten exactly when the system whitens the row's text.
    @Environment(\.backgroundProminence) private var backgroundProminence

    private static let barMaxHeight: CGFloat = 11
    private static let barMinHeight: CGFloat = 2
    private static let barWidth: CGFloat = 2
    private static let barSpacing: CGFloat = 1.5

    private static var totalWidth: CGFloat {
        CGFloat(AudioLevelMeter.bandCount) * barWidth + CGFloat(AudioLevelMeter.bandCount - 1) * barSpacing
    }

    public init(meter: AudioLevelMeter, isPlaying: Bool) {
        self.meter = meter
        self.isPlaying = isPlaying
    }

    /// The bars draw into a fixed-size canvas, so each animation tick is a
    /// repaint only. Animating the bar frames instead would force a layout
    /// pass through the hosting view tree thirty times per second.
    public var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: !isPlaying)) { _ in
            let bands = meter.currentBands()
            let color = backgroundProminence == .increased ? Color.white : Color.accentColor
            Canvas { context, size in
                for index in 0..<AudioLevelMeter.bandCount {
                    let height = Self.barMinHeight + CGFloat(bands[index]) * (Self.barMaxHeight - Self.barMinHeight)
                    let x = CGFloat(index) * (Self.barWidth + Self.barSpacing)
                    let rect = CGRect(x: x, y: size.height - height, width: Self.barWidth, height: height)
                    context.fill(Capsule().path(in: rect), with: .color(color))
                }
            }
            .frame(width: Self.totalWidth, height: Self.barMaxHeight)
        }
    }
}
