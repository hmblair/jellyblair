import Foundation
#if canImport(AppKit)
import AppKit
#else
import UIKit
#endif

/// Owns the transcript's centering scrolls: putting a document y at the
/// viewport's center, once per visual line. Glides are driven frame by
/// frame from the view's live offset, so a new target continues from where
/// the view really is instead of snapping to the old target, and a content
/// shift mid-glide moves the glide's endpoints with the content.
@MainActor
final class TranscriptScroller {
    /// How long a tracking scroll glides.
    private static let scrollDuration: TimeInterval = 0.4

    /// The estimated height of the document, for clamping targets.
    var documentHeight: () -> CGFloat = { 0 }

    /// The last vertical center the view scrolled to, so following scrolls
    /// once per visual line, not once per word.
    private var centeredY: CGFloat?

    /// The glide in flight, in the same document coordinates external
    /// shifts adjust.
    private struct Glide {
        var startOffset: CGFloat
        var targetOffset: CGFloat
        var startTime: TimeInterval
        var completion: (@MainActor () -> Void)?
    }

    private var glide: Glide?
    private var displayLink: CADisplayLink?

    #if canImport(AppKit)
    private let scrollView: MomentumCancellingScrollView

    init(scrollView: MomentumCancellingScrollView) {
        self.scrollView = scrollView
    }
    #else
    private let scrollView: UIScrollView

    init(scrollView: UIScrollView) {
        self.scrollView = scrollView
    }
    #endif

    /// Forgets the centered position when the geometry it was measured in
    /// is void.
    func resetCentering() {
        centeredY = nil
    }

    /// Moves the remembered center and any glide in flight with a content
    /// shift, so both stay aligned with the text.
    func shift(by delta: CGFloat) {
        if let centeredY {
            self.centeredY = centeredY + delta
        }
        glide?.startOffset += delta
        glide?.targetOffset += delta
    }

    /// Stops a glide where it stands, when the user takes over. Its
    /// completion never runs, since its landing was abandoned.
    func cancelGlide() {
        glide = nil
        stopDisplayLink()
    }

    /// Scrolls the document y to the viewport's center, unless it is
    /// centered already. The completion runs after an animated scroll
    /// lands, so the caller can verify the landing.
    func center(onY y: CGFloat, forced: Bool, animated: Bool, completion: (@MainActor () -> Void)? = nil) {
        if !forced, let centeredY, abs(y - centeredY) <= 1 {
            completion?()
            return
        }
        centeredY = y
        let target = scrollTarget(centering: y)
        killMomentum()
        guard animated else {
            cancelGlide()
            setOffset(target)
            completion?()
            return
        }
        // A superseded glide's completion is dropped: its landing was
        // abandoned, and only the final landing verifies itself.
        glide = Glide(
            startOffset: currentOffset(),
            targetOffset: target,
            startTime: CACurrentMediaTime(),
            completion: completion
        )
        startDisplayLink()
    }

    // MARK: - Stepping

    private func startDisplayLink() {
        guard displayLink == nil else { return }
        #if canImport(AppKit)
        let link = scrollView.displayLink(target: self, selector: #selector(displayTick(_:)))
        #else
        let link = CADisplayLink(target: self, selector: #selector(displayTick(_:)))
        #endif
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    private func stopDisplayLink() {
        displayLink?.invalidate()
        displayLink = nil
    }

    @objc private nonisolated func displayTick(_ link: CADisplayLink) {
        MainActor.assumeIsolated {
            stepGlide(now: link.timestamp)
        }
    }

    private func stepGlide(now: TimeInterval) {
        guard let glide else {
            stopDisplayLink()
            return
        }
        let progress = min(1, max(0, (now - glide.startTime) / Self.scrollDuration))
        let eased = easeInOut(progress)
        setOffset(glide.startOffset + (glide.targetOffset - glide.startOffset) * eased)
        guard progress >= 1 else { return }
        self.glide = nil
        stopDisplayLink()
        glide.completion?()
    }

    private func easeInOut(_ t: Double) -> CGFloat {
        t < 0.5 ? CGFloat(4 * t * t * t) : CGFloat(1 - pow(-2 * t + 2, 3) / 2)
    }

    // MARK: - The scroll view

    /// The scroll position that puts the document y at the center of the
    /// region between the insets, clamped to the scrollable range.
    private func scrollTarget(centering y: CGFloat) -> CGFloat {
        let (viewportHeight, topInset, bottomInset) = viewportShape()
        let visible = viewportHeight - topInset - bottomInset
        let limit = max(-topInset, documentHeight() - viewportHeight + bottomInset)
        return min(max(y - topInset - visible / 2, -topInset), limit)
    }

    /// Leftover momentum from a user scroll dies with each centering, so
    /// it cannot pull the view off the target afterwards.
    private func killMomentum() {
        #if canImport(AppKit)
        scrollView.dropsMomentum = true
        #else
        if scrollView.isDecelerating {
            scrollView.setContentOffset(scrollView.contentOffset, animated: false)
        }
        #endif
    }

    private func viewportShape() -> (height: CGFloat, topInset: CGFloat, bottomInset: CGFloat) {
        #if canImport(AppKit)
        (scrollView.contentView.bounds.height, scrollView.contentInsets.top, scrollView.contentInsets.bottom)
        #else
        (scrollView.bounds.height, scrollView.contentInset.top, scrollView.contentInset.bottom)
        #endif
    }

    private func currentOffset() -> CGFloat {
        #if canImport(AppKit)
        scrollView.contentView.bounds.origin.y
        #else
        scrollView.contentOffset.y
        #endif
    }

    private func setOffset(_ y: CGFloat) {
        #if canImport(AppKit)
        let clip = scrollView.contentView
        clip.setBoundsOrigin(CGPoint(x: clip.bounds.origin.x, y: y))
        scrollView.reflectScrolledClipView(clip)
        #else
        scrollView.contentOffset = CGPoint(x: 0, y: y)
        #endif
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
