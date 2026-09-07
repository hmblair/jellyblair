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

/// Owns the transcript's colors. The text system stores colors as
/// rendering attributes, and this engine keeps them equal to the
/// resolver's current output everywhere: every color change repaints its
/// whole range at once, and the on-screen part gets the redraw nudge,
/// since drawing picks up attribute changes only through it. Off-screen
/// text draws its updated attributes when a scroll reaches it. The
/// validator covers fragments the text system lays out on its own.
@MainActor
final class TranscriptColorEngine {
    /// The inputs the resolver paints from. The owner updates it before
    /// any repaint that should reflect a change.
    var state = TranscriptColorState()

    private let textView: PlatformTextView
    private let geometry: TranscriptTextGeometry

    init(textView: PlatformTextView, geometry: TranscriptTextGeometry) {
        self.textView = textView
        self.geometry = geometry
    }

    /// Installs the color resolver as the layout manager's rendering-
    /// attributes validator, so fragments the text system lays out on its
    /// own get their colors as they lay out.
    func installValidator() {
        textView.textLayoutManager?.renderingAttributesValidator = { [weak self] layoutManager, fragment in
            MainActor.assumeIsolated {
                self?.validateColors(of: fragment, in: layoutManager)
            }
        }
    }

    /// Repaints the range with the resolver's current colors and redraws
    /// the on-screen part now.
    func repaintColors(in range: NSRange) {
        repaintResolved(range)
        nudgeVisible(intersecting: range)
    }

    /// Repaints the whole document.
    func repaintAllColors() {
        repaintColors(in: NSRange(location: 0, length: geometry.storage?.length ?? 0))
    }

    /// Paints one fragment's final colors through the resolver.
    private func validateColors(of fragment: NSTextLayoutFragment, in layoutManager: NSTextLayoutManager) {
        guard let range = geometry.storageRange(of: fragment.rangeInElement) else { return }
        repaintResolved(range)
    }

    /// Redraws the part of the range that is on screen. Painted attributes
    /// reach already-drawn fragments only through the nudge.
    private func nudgeVisible(intersecting range: NSRange) {
        guard let layoutManager = textView.textLayoutManager,
              let viewport = layoutManager.textViewportLayoutController.viewportRange,
              let viewportRange = geometry.storageRange(of: viewport)
        else { return }
        let visible = NSIntersectionRange(range, viewportRange)
        guard visible.length > 0,
              let textRange = geometry.textRange(forStorage: visible)
        else { return }
        nudgeRedraw(of: textRange, in: layoutManager)
    }

    /// Redraws the range through a zero-length attribute edit, the one
    /// path the view reliably redraws from, then re-lays the range and
    /// pushes its geometry in the same turn. Colors change no metrics, so
    /// the geometry comes back identical and the content stays in place.
    private func nudgeRedraw(of textRange: NSTextRange, in layoutManager: NSTextLayoutManager) {
        guard let storage = geometry.storage,
              let range = geometry.storageRange(of: textRange),
              range.length > 0
        else { return }
        storage.beginEditing()
        storage.edited(.editedAttributes, range: range, changeInLength: 0)
        storage.endEditing()
        layoutManager.ensureLayout(for: textRange)
        geometry.updateContentGeometry()
    }

    /// Paints the range's final colors, as the resolver computes them.
    private func repaintResolved(_ range: NSRange) {
        for segment in TranscriptColorResolver.segments(for: range, state: state) {
            paint(segment.color, range: segment.range)
        }
    }

    /// Applies one color edit, as a rendering attribute on the layout
    /// manager. Rendering attributes change drawing only, so a paint never
    /// invalidates layout and never moves the content.
    private func paint(_ color: PlatformColor, range: NSRange) {
        guard range.length > 0,
              let layoutManager = textView.textLayoutManager,
              let textRange = geometry.textRange(forStorage: range)
        else { return }
        layoutManager.addRenderingAttribute(.foregroundColor, value: color, for: textRange)
    }
}
