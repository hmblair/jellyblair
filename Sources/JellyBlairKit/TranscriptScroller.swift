import Foundation
#if canImport(AppKit)
import AppKit
#else
import UIKit
#endif

/// Owns the transcript's scrolling: centering a target range, keeping the
/// reader's place when a re-layout moves the content, and killing leftover
/// momentum after a programmatic scroll. The document is laid out fully
/// before anything centers, so every measured position is exact.
@MainActor
final class TranscriptScroller {
    /// How long a tracking scroll glides.
    private static let scrollDuration: TimeInterval = 0.4

    /// The last vertical center the view scrolled to, so following scrolls
    /// once per visual line, not once per word.
    private var centeredY: CGFloat?

    private let geometry: TranscriptTextGeometry
    #if canImport(AppKit)
    private let scrollView: MomentumCancellingScrollView

    init(scrollView: MomentumCancellingScrollView, geometry: TranscriptTextGeometry) {
        self.scrollView = scrollView
        self.geometry = geometry
    }
    #else
    private let textView: UITextView

    init(textView: UITextView, geometry: TranscriptTextGeometry) {
        self.textView = textView
        self.geometry = geometry
    }
    #endif

    /// Forgets the centered position when the document is laid out again,
    /// since that gives every position in it a new value.
    func resetCentering() {
        centeredY = nil
    }

    /// Scrolls the range's visual line to the viewport's center, unless it
    /// is centered already.
    func center(onStorageRange range: NSRange, forced: Bool, animated: Bool) {
        guard let targetY = geometry.frame(forStorageRange: range)?.midY else { return }
        if !forced, let centeredY, abs(targetY - centeredY) <= 1 { return }
        centeredY = targetY
        scroll(toCenterY: targetY, animated: animated)
    }

    /// Runs the work and returns its result, then shifts the scroll so the
    /// text at the top of the viewport keeps its place on screen when the
    /// work moved the content. Only the Mac needs the shift: UITextView
    /// adjusts its own offset when the geometry above the viewport changes,
    /// and a manual shift there would double the move.
    func keepingViewport<Result>(_ work: () -> Result) -> Result {
        #if canImport(AppKit)
        let anchor = geometry.viewportAnchorRange()
        let before = anchor.flatMap { geometry.frame(forStorageRange: $0)?.minY }
        let result = work()
        guard let anchor, let before, let after = geometry.frame(forStorageRange: anchor)?.minY else { return result }
        shiftScroll(by: after - before)
        return result
        #else
        return work()
        #endif
    }

    #if canImport(AppKit)
    /// Moves the scroll offset by the delta without animation, so content
    /// that shifted in document coordinates stays put on screen.
    private func shiftScroll(by delta: CGFloat) {
        guard abs(delta) > 0.5 else { return }
        let clip = scrollView.contentView
        clip.setBoundsOrigin(NSPoint(x: clip.bounds.origin.x, y: clip.bounds.origin.y + delta))
        scrollView.reflectScrolledClipView(clip)
        if let centeredY {
            self.centeredY = centeredY + delta
        }
    }
    #endif

    /// Scrolls so the given document y sits at the center of the region
    /// between the insets. Leftover momentum from a user scroll dies here,
    /// so it cannot pull the view off the target afterwards.
    private func scroll(toCenterY y: CGFloat, animated: Bool) {
        #if canImport(AppKit)
        scrollView.dropsMomentum = true
        let clip = scrollView.contentView
        let inset = scrollView.contentInsets
        let target = scrollTarget(centering: y, viewportHeight: clip.bounds.height, topInset: inset.top, bottomInset: inset.bottom)
        let origin = NSPoint(x: clip.bounds.origin.x, y: target)
        if animated {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = Self.scrollDuration
                context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                clip.animator().setBoundsOrigin(origin)
            }
        } else {
            clip.setBoundsOrigin(origin)
            scrollView.reflectScrolledClipView(clip)
        }
        #else
        if textView.isDecelerating {
            textView.setContentOffset(textView.contentOffset, animated: false)
        }
        let inset = textView.contentInset
        let target = scrollTarget(centering: y, viewportHeight: textView.bounds.height, topInset: inset.top, bottomInset: inset.bottom)
        let offset = CGPoint(x: 0, y: target)
        if animated {
            UIView.animate(withDuration: Self.scrollDuration) {
                self.textView.contentOffset = offset
            }
        } else {
            textView.contentOffset = offset
        }
        #endif
    }

    /// The scroll position that puts the document y at the center of the
    /// region between the insets, clamped to the scrollable range.
    private func scrollTarget(centering y: CGFloat, viewportHeight: CGFloat, topInset: CGFloat, bottomInset: CGFloat) -> CGFloat {
        let visible = viewportHeight - topInset - bottomInset
        let limit = max(-topInset, geometry.documentHeight() - viewportHeight + bottomInset)
        return min(max(y - topInset - visible / 2, -topInset), limit)
    }
}

#if canImport(AppKit)
/// A scroll view that swallows the tail of a momentum scroll after a
/// programmatic centering, so leftover momentum cannot pull the view off
/// the target. A fresh user gesture scrolls normally and clears the flag.
final class MomentumCancellingScrollView: NSScrollView {
    /// Set by each programmatic scroll.
    var dropsMomentum = false

    override func scrollWheel(with event: NSEvent) {
        if event.momentumPhase == [] {
            dropsMomentum = false
        } else if dropsMomentum {
            return
        }
        super.scrollWheel(with: event)
    }
}
#endif
