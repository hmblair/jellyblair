import Foundation
#if canImport(AppKit)
import AppKit
#else
import UIKit
#endif

/// Answers geometry and layout questions about the transcript's text view:
/// range conversion, frames, the scroll position, and layout forcing. All
/// layout measurements in the transcript go through here, so the rest of
/// the code shares one definition of each measurement.
@MainActor
final class TranscriptTextGeometry {
    private let textView: PlatformTextView
    #if canImport(AppKit)
    private let scrollView: NSScrollView

    init(textView: NSTextView, scrollView: NSScrollView) {
        self.textView = textView
        self.scrollView = scrollView
    }
    #else
    init(textView: UITextView) {
        self.textView = textView
    }
    #endif

    var layoutManager: NSTextLayoutManager? {
        textView.textLayoutManager
    }

    var storage: NSTextStorage? {
        textView.textStorage
    }

    // MARK: - Range conversion

    /// The text range for the UTF-16 storage range.
    func textRange(forStorage range: NSRange) -> NSTextRange? {
        guard let contentManager = layoutManager?.textContentManager,
              let start = contentManager.location(contentManager.documentRange.location, offsetBy: range.location),
              let end = contentManager.location(start, offsetBy: range.length)
        else { return nil }
        return NSTextRange(location: start, end: end)
    }

    /// The UTF-16 storage range for the text range.
    func storageRange(of textRange: NSTextRange) -> NSRange? {
        guard let contentManager = layoutManager?.textContentManager else { return nil }
        let location = contentManager.offset(from: contentManager.documentRange.location, to: textRange.location)
        let length = contentManager.offset(from: textRange.location, to: textRange.endLocation)
        return NSRange(location: location, length: length)
    }

    // MARK: - Viewport

    /// The container's origin inside the text view: frames from the layout
    /// gain it, fragment frames do not.
    private func containerOrigin() -> CGPoint {
        #if canImport(AppKit)
        textView.textContainerOrigin
        #else
        CGPoint(x: textView.textContainerInset.left, y: textView.textContainerInset.top)
        #endif
    }

    /// The vertical scroll offset in text layout coordinates.
    func scrollOffsetY() -> CGFloat {
        #if canImport(AppKit)
        scrollView.contentView.bounds.origin.y - containerOrigin().y
        #else
        textView.contentOffset.y - containerOrigin().y
        #endif
    }

    /// A zero-length range at the start of the text at the current scroll
    /// offset, whose frame anchors offset corrections. Asked of the layout
    /// manager directly: the render viewport lags programmatic scrolls, so
    /// anchoring on it corrects against the wrong text.
    func viewportAnchorRange() -> NSRange? {
        guard let layoutManager,
              let contentManager = layoutManager.textContentManager,
              let fragment = layoutManager.textLayoutFragment(for: CGPoint(x: 0, y: max(0, scrollOffsetY())))
        else { return nil }
        let start = contentManager.offset(from: contentManager.documentRange.location, to: fragment.rangeInElement.location)
        return NSRange(location: start, length: 0)
    }

    // MARK: - Frames

    /// The range's frame in text view coordinates, from the layout.
    func frame(forStorageRange range: NSRange) -> CGRect? {
        guard let layoutManager,
              let textRange = textRange(forStorage: range)
        else { return nil }
        layoutManager.ensureLayout(for: textRange)
        var frame: CGRect?
        layoutManager.enumerateTextSegments(in: textRange, type: .standard, options: [.rangeNotRequired]) { _, segmentFrame, _, _ in
            frame = segmentFrame
            return false
        }
        guard var found = frame else { return nil }
        let origin = containerOrigin()
        found.origin.x += origin.x
        found.origin.y += origin.y
        return found
    }

    /// The document's height. Exact, since the document is laid out fully
    /// before anything measures it.
    func documentHeight() -> CGFloat {
        layoutManager?.usageBoundsForTextContainer.height ?? 0
    }

    // MARK: - Layout forcing

    /// Lays the storage range out, so its positions are exact.
    func ensureLayout(forStorage range: NSRange) {
        guard let layoutManager,
              let textRange = textRange(forStorage: range)
        else { return }
        layoutManager.ensureLayout(for: textRange)
    }

    /// Pushes the laid-out extent into the view, so the scroll limit and
    /// the clip constraint see the true size right away instead of the
    /// stale document height.
    func updateContentGeometry() {
        #if canImport(AppKit)
        textView.needsLayout = true
        textView.layoutSubtreeIfNeeded()
        #else
        textView.layoutIfNeeded()
        #endif
    }
}
