import Foundation
#if canImport(AppKit)
import AppKit
#else
import UIKit
#endif

/// One display line ready to render: its text without the trailing
/// newline, and the vertical spacing around it.
struct TranscriptRenderLine {
    let text: NSAttributedString
    let spacingBefore: CGFloat
    let spacingAfter: CGFloat
}

/// How an ensure call changed the geometry, and what the caller owes the
/// screen for it.
enum TranscriptCoverage {
    /// The window grew in place; content the viewport showed moved by the
    /// delta, so the caller shifts the scroll with it.
    case extended(shift: CGFloat)
    /// The window was rebuilt somewhere else; every prior position is void.
    case relocated
}

/// The transcript's vertical geometry. Lines are measured lazily in one
/// contiguous window around where the reader is; lines outside the window
/// stand at the average measured height. Positions inside the window are
/// exact relative to each other, which is what exact centering needs; the
/// estimated tails only sway the scroll bar's proportions. Every mutation
/// reports the distance it moved the measured content, so the caller keeps
/// the screen still by shifting the scroll with it.
@MainActor
final class TranscriptLineMetrics {
    /// The farthest the window extends toward a target, in lines, before
    /// extending would be dearer than starting over there.
    private static let relocationDistance = 400

    /// The estimate for a line no measurement has informed yet.
    private static let initialEstimate: CGFloat = 44

    private let renderer: TranscriptLineRenderer
    private var lines: [TranscriptRenderLine] = []
    private(set) var width: CGFloat = 0

    /// The first measured line.
    private var low = 0
    /// Document y of the first measured line's top.
    private var lowTop: CGFloat = 0
    /// The measured lines' heights from `low` on, spacing included.
    private var heights: [CGFloat] = []
    /// prefix[i] is the sum of heights[0..<i].
    private var prefix: [CGFloat] = [0]

    /// Running mean of every height measured at this width, the estimate
    /// for unmeasured lines.
    private var averageHeight: CGFloat = TranscriptLineMetrics.initialEstimate
    private var averageCount = 0

    init(renderer: TranscriptLineRenderer) {
        self.renderer = renderer
    }

    var lineCount: Int { lines.count }

    /// The line past the last measured one.
    private var high: Int { low + heights.count }

    // MARK: - Content and width

    /// Installs new lines and forgets every measurement.
    func setLines(_ newLines: [TranscriptRenderLine]) {
        lines = newLines
        clearWindow(around: 0)
    }

    /// Adopts a new width. Old heights are void; the average carries over
    /// scaled, since text height grows roughly as width shrinks.
    func setWidth(_ newWidth: CGFloat) {
        guard newWidth != width else { return }
        if width > 0, newWidth > 0 {
            averageHeight = max(1, averageHeight * width / newWidth)
        }
        width = newWidth
        clearWindow(around: low)
    }

    /// Rebuilds the empty window at the line's estimated position.
    func relocateWindow(around line: Int) {
        clearWindow(around: line)
    }

    private func clearWindow(around line: Int) {
        low = min(max(line, 0), max(lines.count - 1, 0))
        heights = []
        prefix = [0]
        lowTop = CGFloat(low) * averageHeight
    }

    // MARK: - Positions

    /// Document y of the line's top. Exact inside the window, estimated
    /// beyond it. `lineCount` names the document's end.
    func top(of line: Int) -> CGFloat {
        if line < low {
            return lowTop - CGFloat(low - line) * averageHeight
        }
        if line >= high {
            return lowTop + prefix[heights.count] + CGFloat(line - high) * averageHeight
        }
        return lowTop + prefix[line - low]
    }

    /// The full height of a measured line, or the estimate.
    func height(of line: Int) -> CGFloat {
        guard line >= low, line < high else { return averageHeight }
        return heights[line - low]
    }

    /// Document y where the line's text starts, under its leading spacing.
    func textTop(of line: Int) -> CGFloat {
        top(of: line) + lines[line].spacingBefore
    }

    /// The height of the line's text alone.
    func textHeight(of line: Int) -> CGFloat {
        height(of: line) - lines[line].spacingBefore - lines[line].spacingAfter
    }

    /// The estimated height of the whole document.
    func documentHeight() -> CGFloat {
        guard !lines.isEmpty else { return 0 }
        return top(of: lines.count)
    }

    /// The line whose span contains the document y, clamped to the lines.
    func lineIndex(atY y: CGFloat) -> Int {
        guard !lines.isEmpty else { return 0 }
        if y < lowTop {
            let above = Int(ceil((lowTop - y) / averageHeight))
            return max(0, low - above)
        }
        let windowBottom = lowTop + prefix[heights.count]
        if y >= windowBottom {
            let below = Int((y - windowBottom) / averageHeight)
            return min(lines.count - 1, high + below)
        }
        let offset = prefix.partitioningIndex { $0 > y - lowTop }
        return low + max(0, offset - 1)
    }

    /// True when the line's height is measured, not estimated.
    func isMeasured(_ line: Int) -> Bool {
        line >= low && line < high
    }

    // MARK: - Measuring

    /// Brings the lines into the measured window: nearby ranges extend the
    /// window in place, and the result carries the shift the extension
    /// caused; a far range rebuilds the window there instead, voiding all
    /// prior positions.
    func ensureMeasured(covering range: ClosedRange<Int>) -> TranscriptCoverage {
        guard width > 0, !lines.isEmpty else { return .extended(shift: 0) }
        let target = max(0, range.lowerBound)...min(lines.count - 1, range.upperBound)
        if heights.isEmpty {
            clearWindow(around: target.lowerBound)
        } else if target.lowerBound > high + Self.relocationDistance || target.upperBound < low - Self.relocationDistance {
            clearWindow(around: target.lowerBound)
            extendWindow(toCover: target)
            return .relocated
        }
        // The low line's top names a fixed spot in the content the viewport
        // may be showing; how far it moves is what the screen must absorb.
        let referenceLine = low
        let referenceBefore = top(of: referenceLine)
        extendWindow(toCover: target)
        return .extended(shift: top(of: referenceLine) - referenceBefore)
    }

    /// Grows the window until it covers the range, measuring line by line,
    /// then re-anchors the document's top at zero.
    private func extendWindow(toCover target: ClosedRange<Int>) {
        while high <= target.upperBound {
            heights.append(measure(high))
            prefix.append(prefix[heights.count - 1] + heights[heights.count - 1])
        }
        var prepended: [CGFloat] = []
        while low - prepended.count > target.lowerBound {
            prepended.append(measure(low - prepended.count - 1))
        }
        if !prepended.isEmpty {
            heights.insert(contentsOf: prepended.reversed(), at: 0)
            low -= prepended.count
            lowTop -= prepended.reduce(0, +)
            rebuildPrefix()
        }
        // With everything above the window estimated at the average, the
        // document's top stays pinned at zero.
        lowTop = CGFloat(low) * averageHeight
    }

    private func rebuildPrefix() {
        prefix = [0]
        prefix.reserveCapacity(heights.count + 1)
        for height in heights {
            prefix.append(prefix[prefix.count - 1] + height)
        }
    }

    /// Measures one line's full height and feeds the running average.
    private func measure(_ line: Int) -> CGFloat {
        let spacing = lines[line].spacingBefore + lines[line].spacingAfter
        let height = renderer.textHeight(of: lines[line].text, width: width) + spacing
        averageCount += 1
        averageHeight += (height - averageHeight) / CGFloat(averageCount)
        return height
    }
}
