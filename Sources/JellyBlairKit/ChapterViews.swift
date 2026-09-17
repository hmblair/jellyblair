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
    /// True when the sleep timer sits at this chapter's end.
    let sleepsAfter: Bool
    let meter: AudioLevelMeter
    /// The phrase whose occurrences in the title color as search matches.
    let searchQuery: String
    let searchIsCaseSensitive: Bool

    public init(chapter: Chapter, state: ChapterRowState, sleepsAfter: Bool, meter: AudioLevelMeter, searchQuery: String, searchIsCaseSensitive: Bool) {
        self.chapter = chapter
        self.state = state
        self.sleepsAfter = sleepsAfter
        self.meter = meter
        self.searchQuery = searchQuery
        self.searchIsCaseSensitive = searchIsCaseSensitive
    }

    /// Width of the gutter on each side of the content. The position marker
    /// centers in the leading one, so it sits midway between the row's edge
    /// and the content; the trailing one mirrors it and holds the sleep
    /// marker, so the content stays centered whatever the markers show.
    /// The separators span only the content between the gutters.
    private static let gutterWidth: CGFloat = 32

    private var isCurrent: Bool {
        if case .current = state { return true }
        return false
    }

    @State private var isHovering = false

    public var body: some View {
        HStack(spacing: 0) {
            icon
                .frame(width: Self.gutterWidth)
            Text(highlightedTitle)
                .fontWeight(isCurrent ? .semibold : .regular)
                .foregroundStyle(state == .played ? .secondary : .primary)
            Spacer()
            Text(formatTime(chapter.durationSeconds))
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
            sleepMarker
                .frame(width: Self.gutterWidth)
        }
        .padding(.vertical, 6)
        // The highlight bounds to the visible content: it skips the icon
        // column when the row has no mark, and cannot overhang the list edges
        // the way a full row background does.
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.primary.opacity(0.06))
                .opacity(isHovering ? 1 : 0)
                .animation(.easeOut(duration: 0.1), value: isHovering)
                // The pill overhangs the content's ends slightly; a marked
                // row's pill reaches over its markers too.
                .padding(.leading, state == .upcoming ? Self.gutterWidth - 8 : 0)
                .padding(.trailing, sleepsAfter ? 0 : Self.gutterWidth - 8)
        )
        .onHover { isHovering = $0 }
        // Zero side insets: the gutters are the row's whole margin, so the
        // icon's centering within them holds against the pane's edge.
        .listRowInsets(EdgeInsets())
        // Clear rows, so the pane's backdrop shows through them.
        .listRowBackground(Color.clear)
        // The separator spans only the content between the gutters, so its
        // ends stay symmetric and clear of the marker icons.
        .alignmentGuide(.listRowSeparatorLeading) { dimensions in
            dimensions[.leading] + Self.gutterWidth
        }
        .alignmentGuide(.listRowSeparatorTrailing) { dimensions in
            dimensions[.trailing] - Self.gutterWidth
        }
    }

    /// The title with the searched phrase in the match color.
    private var highlightedTitle: AttributedString {
        var title = AttributedString(chapter.title)
        for nsRange in findOccurrences(of: searchQuery, in: chapter.title as NSString, caseSensitive: searchIsCaseSensitive) {
            guard let range = Range(nsRange, in: title) else { continue }
            title[range].foregroundColor = Color(PlatformColor.matchHighlight)
        }
        return title
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

    @ViewBuilder
    private var sleepMarker: some View {
        if sleepsAfter {
            sleepTimerIcon.plain
                .font(.caption)
                .foregroundStyle(Color.accentColor)
        } else {
            Color.clear
        }
    }
}
