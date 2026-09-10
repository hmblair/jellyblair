import Foundation
#if canImport(AppKit)
import AppKit
#else
import UIKit
#endif

/// The inputs the color resolver paints from, in UTF-16 storage offsets.
struct TranscriptColorState {
    /// The storage offset where the read region ends.
    var readEnd = 0
    /// The storage range of the current line.
    var currentLineRange: NSRange?
    /// The storage offset where the spoken cue starts, splitting the
    /// current line into its read and unread parts.
    var spokenCueStart: Int?
    /// The storage range of the spoken cue. Nil when the cue is empty.
    var spokenCueRange: NSRange?
    /// The storage ranges of the search matches, in order.
    var matches: [NSRange] = []
}

/// Computes the color runs of any storage range from a color state. Pure
/// functions: the single source of what color every character has.
enum TranscriptColorResolver {
    /// The color runs painting the range, in paint order: the positional
    /// base, then the matches, clipped against the spoken cue so the
    /// spoken word wins.
    static func segments(for range: NSRange, state: TranscriptColorState) -> [(color: PlatformColor, range: NSRange)] {
        baseSegments(for: range, state: state) + matchSegments(intersecting: range, state: state)
    }

    /// The positional color runs over the range, in paint order: the read
    /// region, the unread region, and the current line's runs on top.
    private static func baseSegments(for range: NSRange, state: TranscriptColorState) -> [(color: PlatformColor, range: NSRange)] {
        var segments: [(color: PlatformColor, range: NSRange)] = []
        let end = range.location + range.length
        if state.readEnd > range.location {
            segments.append((TranscriptStyle.read, NSRange(location: range.location, length: min(state.readEnd, end) - range.location)))
        }
        let unreadStart = max(state.readEnd, range.location)
        if end > unreadStart {
            segments.append((TranscriptStyle.unread, NSRange(location: unreadStart, length: end - unreadStart)))
        }
        if let line = state.currentLineRange, NSIntersectionRange(range, line).length > 0 {
            segments += currentLineSegments(state: state, line: line)
        }
        return segments
    }

    /// The color runs of the current line, in paint order: the whole line
    /// unread, then its read part and spoken cue on top.
    private static func currentLineSegments(state: TranscriptColorState, line: NSRange) -> [(color: PlatformColor, range: NSRange)] {
        var segments: [(color: PlatformColor, range: NSRange)] = [(TranscriptStyle.unread, line)]
        guard let cueStart = state.spokenCueStart else { return segments }
        if cueStart > line.location {
            segments.append((TranscriptStyle.read, NSRange(location: line.location, length: cueStart - line.location)))
        }
        if let cueRange = state.spokenCueRange {
            segments.append((TranscriptStyle.spoken, cueRange))
        }
        return segments
    }

    /// The match color runs over the occurrences intersecting the range.
    private static func matchSegments(intersecting range: NSRange, state: TranscriptColorState) -> [(color: PlatformColor, range: NSRange)] {
        guard !state.matches.isEmpty else { return [] }
        var segments: [(color: PlatformColor, range: NSRange)] = []
        var position = state.matches.partitioningIndex { $0.location + $0.length > range.location }
        while position < state.matches.count, state.matches[position].location < range.location + range.length {
            segments += matchSegments(of: state.matches[position], clippedBy: state.spokenCueRange)
            position += 1
        }
        return segments
    }

    /// The match color runs of one occurrence, minus the cue.
    private static func matchSegments(of match: NSRange, clippedBy cue: NSRange?) -> [(color: PlatformColor, range: NSRange)] {
        guard let cue else {
            return [(TranscriptStyle.match, match)]
        }
        var segments: [(color: PlatformColor, range: NSRange)] = []
        let end = match.location + match.length
        let cueEnd = cue.location + cue.length
        if cue.location > match.location {
            segments.append((TranscriptStyle.match, NSRange(location: match.location, length: min(cue.location, end) - match.location)))
        }
        if end > cueEnd {
            let start = max(cueEnd, match.location)
            segments.append((TranscriptStyle.match, NSRange(location: start, length: end - start)))
        }
        return segments
    }
}

/// Owns the transcript's colors, one line at a time. A line's colored text
/// is its base text with the resolver's current runs applied; the painter
/// caches each colored line until the color state moves past it, and the
/// view redraws only the lines whose colors changed.
@MainActor
final class TranscriptLinePainter {
    /// The inputs the resolver paints from. The owner updates it through
    /// setState before any repaint that should reflect a change.
    private(set) var state = TranscriptColorState()

    private var baseLines: [TranscriptRenderLine] = []
    private var lineRanges: [NSRange] = []
    private var cache: [Int: NSAttributedString] = [:]

    /// Installs the lines and their storage ranges and drops every cached
    /// coloring.
    func setContent(lines: [TranscriptRenderLine], ranges: [NSRange]) {
        baseLines = lines
        lineRanges = ranges
        cache.removeAll()
    }

    /// Adopts a new color state and drops the cached lines it invalidates.
    /// Passing nil drops them all.
    func setState(_ newState: TranscriptColorState, invalidating lines: ClosedRange<Int>?) {
        state = newState
        guard let lines else {
            cache.removeAll()
            return
        }
        for line in lines {
            cache.removeValue(forKey: line)
        }
    }

    /// The line's text with its current colors, cached until invalidated.
    func coloredLine(_ index: Int) -> NSAttributedString {
        if let cached = cache[index] {
            return cached
        }
        let base = baseLines[index].text
        let range = lineRanges[index]
        let colored = NSMutableAttributedString(attributedString: base)
        for segment in TranscriptColorResolver.segments(for: range, state: state) {
            let overlap = NSIntersectionRange(segment.range, range)
            guard overlap.length > 0 else { continue }
            let local = NSRange(location: overlap.location - range.location, length: overlap.length)
            colored.addAttribute(.foregroundColor, value: segment.color, range: local)
        }
        cache[index] = colored
        return colored
    }
}
