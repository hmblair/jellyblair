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
    /// The phrase whose occurrences in the title color as search matches.
    let searchQuery: String
    let searchIsCaseSensitive: Bool

    public init(chapter: Chapter, state: ChapterRowState, meter: AudioLevelMeter, searchQuery: String, searchIsCaseSensitive: Bool) {
        self.chapter = chapter
        self.state = state
        self.meter = meter
        self.searchQuery = searchQuery
        self.searchIsCaseSensitive = searchIsCaseSensitive
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
            Text(highlightedTitle)
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
}
