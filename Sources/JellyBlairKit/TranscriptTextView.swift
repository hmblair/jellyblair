import SwiftUI
#if canImport(AppKit)
import AppKit
#else
import UIKit
#endif

/// Reaches the transcript text view from SwiftUI controls, so the tracking
/// button can center the spoken word on demand.
@MainActor
public final class TranscriptController {
    fileprivate weak var coordinator: TranscriptTextCoordinator?

    public init() {}

    /// Centers the spoken word now.
    public func centerOnSpokenWord(animated: Bool) {
        coordinator?.centerOnSpokenWord(forced: true, animated: animated)
    }
}

/// The transcript as one native text view. The text system lays the whole
/// book out lazily, answers where any character range sits, and scrolls to
/// it, so following the narration needs no view-level machinery. Word colors
/// update as attribute edits on the spoken ranges.
public struct TranscriptTextView {
    let lines: [LyricLine]
    /// Indices of lines drawn as chapter headings.
    let titleLineIndices: Set<Int>
    /// The playback position the coloring and centering follow.
    let positionSeconds: Double
    /// True while the view keeps the spoken word centered.
    let isTracking: Bool
    /// Space kept clear at the top, under the floating filter bar.
    let topInset: CGFloat
    /// Resting clearance under the last line.
    let bottomInset: CGFloat
    /// Side padding of the text.
    let horizontalPadding: CGFloat
    let controller: TranscriptController
    /// Called with the clicked word's cue.
    let onWordTap: (LyricCue) -> Void
    /// Called when a click lands beside the words, on the line itself.
    let onLineTap: (LyricLine) -> Void
    /// Called when the user scrolls the transcript themselves.
    let onUserScroll: () -> Void

    public init(
        lines: [LyricLine],
        titleLineIndices: Set<Int>,
        positionSeconds: Double,
        isTracking: Bool,
        topInset: CGFloat,
        bottomInset: CGFloat,
        horizontalPadding: CGFloat,
        controller: TranscriptController,
        onWordTap: @escaping (LyricCue) -> Void,
        onLineTap: @escaping (LyricLine) -> Void,
        onUserScroll: @escaping () -> Void
    ) {
        self.lines = lines
        self.titleLineIndices = titleLineIndices
        self.positionSeconds = positionSeconds
        self.isTracking = isTracking
        self.topInset = topInset
        self.bottomInset = bottomInset
        self.horizontalPadding = horizontalPadding
        self.controller = controller
        self.onWordTap = onWordTap
        self.onLineTap = onLineTap
        self.onUserScroll = onUserScroll
    }
}

#if canImport(AppKit)
extension TranscriptTextView: NSViewRepresentable {
    public func makeCoordinator() -> TranscriptTextCoordinator {
        TranscriptTextCoordinator()
    }

    public func makeNSView(context: Context) -> NSScrollView {
        let view = context.coordinator.makeScrollView()
        controller.coordinator = context.coordinator
        return view
    }

    public func updateNSView(_ view: NSScrollView, context: Context) {
        controller.coordinator = context.coordinator
        context.coordinator.update(from: self)
    }
}
#else
extension TranscriptTextView: UIViewRepresentable {
    public func makeCoordinator() -> TranscriptTextCoordinator {
        TranscriptTextCoordinator()
    }

    public func makeUIView(context: Context) -> UITextView {
        let view = context.coordinator.makeTextView()
        controller.coordinator = context.coordinator
        return view
    }

    public func updateUIView(_ view: UITextView, context: Context) {
        controller.coordinator = context.coordinator
        context.coordinator.update(from: self)
    }
}
#endif

/// Owns the platform text view: builds its attributed content, recolors the
/// spoken ranges on each position update, and keeps the spoken word centered
/// while tracking is on.
@MainActor
public final class TranscriptTextCoordinator: NSObject {
    private var lines: [LyricLine] = []
    private var titleLineIndices: Set<Int> = []
    /// UTF-16 range of each line's text inside the storage.
    private var lineRanges: [NSRange] = []
    /// Start times of the timed lines with their array positions, in order,
    /// for binary-searching the current line.
    private var timedLines: [(start: Double, position: Int)] = []

    private var view: TranscriptTextView?
    private var currentLine: Int?
    private var spokenCueIndex: Int?
    /// The last vertical center the view scrolled to, so following scrolls
    /// once per visual line, not once per word.
    private var centeredY: CGFloat?

    /// How long a tracking scroll glides.
    private static let scrollDuration: TimeInterval = 0.4

    #if canImport(AppKit)
    private var scrollView: NSScrollView!
    private var textView: NSTextView!
    private var scrollObserver: NSObjectProtocol?
    #else
    private var textView: UITextView!
    #endif

    // MARK: - View construction

    #if canImport(AppKit)
    func makeScrollView() -> NSScrollView {
        let textView = NSTextView(usingTextLayoutManager: true)
        textView.isEditable = false
        textView.isSelectable = false
        textView.drawsBackground = false
        textView.textContainer?.widthTracksTextView = true
        textView.autoresizingMask = [.width]
        self.textView = textView

        let scrollView = NSScrollView()
        scrollView.documentView = textView
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.automaticallyAdjustsContentInsets = false
        self.scrollView = scrollView

        let click = NSClickGestureRecognizer(target: self, action: #selector(handleClick(_:)))
        textView.addGestureRecognizer(click)

        scrollObserver = NotificationCenter.default.addObserver(
            forName: NSScrollView.willStartLiveScrollNotification,
            object: scrollView,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.view?.onUserScroll()
            }
        }
        return scrollView
    }
    #else
    func makeTextView() -> UITextView {
        let textView = UITextView(usingTextLayoutManager: true)
        textView.isEditable = false
        textView.isSelectable = false
        textView.backgroundColor = .clear
        // The centering math reads contentInset back, so the system must not adjust it.
        textView.contentInsetAdjustmentBehavior = .never
        textView.delegate = self
        self.textView = textView

        let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
        textView.addGestureRecognizer(tap)
        return textView
    }
    #endif

    deinit {
        #if canImport(AppKit)
        if let scrollObserver {
            NotificationCenter.default.removeObserver(scrollObserver)
        }
        #endif
    }

    // MARK: - Updates

    func update(from view: TranscriptTextView) {
        // Array equality short-circuits on shared storage, so this is cheap per tick.
        let contentChanged = view.lines != lines || view.titleLineIndices != titleLineIndices
        self.view = view
        applyInsets()
        if contentChanged {
            rebuildContent()
        }
        followPosition(recentered: contentChanged)
    }

    /// The insets last applied, so the per-tick update skips the setters:
    /// re-assigning them can invalidate layout even with equal values.
    private var appliedInsets: (top: CGFloat, bottom: CGFloat, horizontal: CGFloat)?

    private func applyInsets() {
        guard let view else { return }
        let insets = (top: view.topInset, bottom: view.bottomInset, horizontal: view.horizontalPadding)
        guard appliedInsets == nil || appliedInsets! != insets else { return }
        appliedInsets = insets
        #if canImport(AppKit)
        scrollView.contentInsets = NSEdgeInsets(top: insets.top, left: 0, bottom: insets.bottom, right: 0)
        textView.textContainerInset = NSSize(width: insets.horizontal, height: 0)
        #else
        textView.contentInset = UIEdgeInsets(top: insets.top, left: 0, bottom: insets.bottom, right: 0)
        textView.textContainerInset = UIEdgeInsets(top: 0, left: insets.horizontal, bottom: 0, right: insets.horizontal)
        #endif
    }

    /// Recolors and recenters for the view's position. Skips work while the
    /// current line and spoken cue are unchanged.
    private func followPosition(recentered: Bool) {
        guard let view else { return }
        let line = lineIndex(at: view.positionSeconds)
        let cue = line.flatMap { spokenCueIndex(in: lines[$0], at: view.positionSeconds) }
        let moved = line != currentLine || cue != spokenCueIndex
        guard moved || recentered else { return }
        let previousLine = currentLine
        currentLine = line
        spokenCueIndex = cue
        // Measured before the recolor, whose attribute edits invalidate the
        // layout the frame is read from.
        let target = view.isTracking ? spokenWordFrame() : nil
        if moved {
            recolor(fromLine: previousLine, toLine: line, cue: cue)
        }
        if view.isTracking, let target {
            center(on: target, forced: recentered, animated: !recentered)
        }
    }

    /// The array position of the line containing the playback position.
    private func lineIndex(at seconds: Double) -> Int? {
        guard seconds > 0 else { return nil }
        var low = 0
        var high = timedLines.count
        while low < high {
            let mid = (low + high) / 2
            if timedLines[mid].start <= seconds {
                low = mid + 1
            } else {
                high = mid
            }
        }
        return low > 0 ? timedLines[low - 1].position : nil
    }

    /// The index of the last cue starting at or before the position.
    private func spokenCueIndex(in line: LyricLine, at seconds: Double) -> Int? {
        line.cues.lastIndex(where: { $0.startSeconds <= seconds })
    }

    // MARK: - Content

    /// The text styles, from the platform's semantic fonts and colors so the
    /// view follows the system appearance.
    private enum Style {
        static var body: PlatformFont { .preferredFont(forTextStyle: .title2) }
        static var title: PlatformFont {
            let base = PlatformFont.preferredFont(forTextStyle: .title1)
            #if canImport(AppKit)
            return NSFontManager.shared.convert(base, toHaveTrait: .boldFontMask)
            #else
            guard let descriptor = base.fontDescriptor.withSymbolicTraits(.traitBold) else { return base }
            return UIFont(descriptor: descriptor, size: 0)
            #endif
        }
        static var read: PlatformColor { .secondaryLabel }
        static var unread: PlatformColor { .label }
        static var spoken: PlatformColor { .accent }

        static var paragraph: NSParagraphStyle {
            let style = NSMutableParagraphStyle()
            style.paragraphSpacing = 4
            return style
        }

        static var titleParagraph: NSParagraphStyle {
            let style = NSMutableParagraphStyle()
            style.paragraphSpacing = 4
            style.paragraphSpacingBefore = 12
            return style
        }
    }

    /// Builds the storage from the lines: one paragraph per line, chapter
    /// headings in the title style, everything in the unread color. The
    /// position coloring follows separately.
    private func rebuildContent() {
        guard let view else { return }
        lines = view.lines
        titleLineIndices = view.titleLineIndices
        lineRanges = []
        timedLines = []
        currentLine = nil
        spokenCueIndex = nil
        centeredY = nil

        let content = NSMutableAttributedString()
        for (position, line) in lines.enumerated() {
            let isTitle = view.titleLineIndices.contains(line.index)
            let attributes: [NSAttributedString.Key: Any] = [
                .font: isTitle ? Style.title : Style.body,
                .foregroundColor: Style.unread,
                .paragraphStyle: isTitle ? Style.titleParagraph : Style.paragraph,
            ]
            let text = NSAttributedString(string: line.text + "\n", attributes: attributes)
            lineRanges.append(NSRange(location: content.length, length: (line.text as NSString).length))
            if let start = line.startSeconds {
                timedLines.append((start: start, position: position))
            }
            content.append(text)
        }
        storage?.setAttributedString(content)
    }

    private var storage: NSTextStorage? {
        textView.textStorage
    }

    /// Recolors from the stored line and cue to the given ones: whole lines
    /// take their read or unread color, and the current line colors its read
    /// part, spoken cue, and unread rest.
    private func recolor(fromLine previousLine: Int?, toLine line: Int?, cue: Int?) {
        guard let storage else { return }
        let oldLine = previousLine ?? 0
        let newLine = line ?? 0
        for position in min(oldLine, newLine)...max(oldLine, newLine) where lineRanges.indices.contains(position) {
            let read = line.map { position < $0 } ?? false
            storage.addAttribute(.foregroundColor, value: read ? Style.read : Style.unread, range: lineRanges[position])
        }
        guard let line, lineRanges.indices.contains(line) else { return }
        let range = lineRanges[line]
        storage.addAttribute(.foregroundColor, value: Style.unread, range: range)
        guard let cue else { return }
        let spoken = lines[line].cues[cue]
        let text = lines[line].text
        let readEnd = utf16Offset(ofCharacter: spoken.startPosition, in: text)
        let spokenEnd = utf16Offset(ofCharacter: spoken.endPosition, in: text)
        if readEnd > 0 {
            storage.addAttribute(.foregroundColor, value: Style.read, range: NSRange(location: range.location, length: readEnd))
        }
        if spokenEnd > readEnd {
            storage.addAttribute(.foregroundColor, value: Style.spoken, range: NSRange(location: range.location + readEnd, length: spokenEnd - readEnd))
        }
    }

    // MARK: - Centering

    /// Scrolls the spoken word's visual line to the viewport's center. The
    /// unforced form skips targets on the already-centered visual line, so
    /// tracking steps once per line of text.
    func centerOnSpokenWord(forced: Bool, animated: Bool) {
        guard let target = spokenWordFrame() else { return }
        center(on: target, forced: forced, animated: animated)
    }

    /// Scrolls the given spoken-word frame to the viewport's center, unless
    /// its visual line is centered already.
    private func center(on target: CGRect, forced: Bool, animated: Bool) {
        prepareLayout(around: target.midY)
        let targetY = spokenWordFrame()?.midY ?? target.midY
        if !forced, let centeredY, abs(targetY - centeredY) <= 1 { return }
        centeredY = targetY
        scroll(toCenterY: targetY, animated: animated)
    }

    /// Lays out the text around the given document y before a scroll, so the
    /// glide moves through settled geometry instead of refining estimates on
    /// every animation frame.
    private func prepareLayout(around y: CGFloat) {
        guard let layoutManager = textView.textLayoutManager else { return }
        #if canImport(AppKit)
        let viewportHeight = scrollView.contentView.bounds.height
        #else
        let viewportHeight = textView.bounds.height
        #endif
        let corridor = CGRect(x: 0, y: y - viewportHeight * 2, width: textView.bounds.width, height: viewportHeight * 4)
        layoutManager.ensureLayout(for: corridor)
    }

    /// The spoken word's frame in text view coordinates, from the layout.
    private func spokenWordFrame() -> CGRect? {
        guard let layoutManager = textView.textLayoutManager,
              let contentManager = layoutManager.textContentManager,
              let range = spokenTargetRange(),
              let textRange = textRange(from: range, in: contentManager)
        else { return nil }
        layoutManager.ensureLayout(for: textRange)
        var frame: CGRect?
        layoutManager.enumerateTextSegments(in: textRange, type: .standard, options: [.rangeNotRequired]) { _, segmentFrame, _, _ in
            frame = segmentFrame
            return false
        }
        guard var found = frame else { return nil }
        #if canImport(AppKit)
        let origin = textView.textContainerOrigin
        found.origin.x += origin.x
        found.origin.y += origin.y
        #else
        found.origin.x += textView.textContainerInset.left
        found.origin.y += textView.textContainerInset.top
        #endif
        return found
    }

    /// The storage range centering targets: the spoken cue, or the current
    /// line's start before its first cue.
    private func spokenTargetRange() -> NSRange? {
        guard let currentLine, lineRanges.indices.contains(currentLine) else { return nil }
        let range = lineRanges[currentLine]
        guard let spokenCueIndex else {
            return NSRange(location: range.location, length: 0)
        }
        let line = lines[currentLine]
        let cue = line.cues[spokenCueIndex]
        let start = utf16Offset(ofCharacter: cue.startPosition, in: line.text)
        let end = utf16Offset(ofCharacter: cue.endPosition, in: line.text)
        return NSRange(location: range.location + start, length: max(0, end - start))
    }

    private func textRange(from range: NSRange, in contentManager: NSTextContentManager) -> NSTextRange? {
        guard let start = contentManager.location(contentManager.documentRange.location, offsetBy: range.location),
              let end = contentManager.location(start, offsetBy: range.length)
        else { return nil }
        return NSTextRange(location: start, end: end)
    }

    /// Scrolls so the given document y sits at the center of the region
    /// between the insets.
    private func scroll(toCenterY y: CGFloat, animated: Bool) {
        guard let view else { return }
        #if canImport(AppKit)
        let clip = scrollView.contentView
        let visible = clip.bounds.height - view.topInset - view.bottomInset
        let limit = max(-view.topInset, textView.frame.height - clip.bounds.height + view.bottomInset)
        let target = min(max(y - view.topInset - visible / 2, -view.topInset), limit)
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
        let inset = textView.contentInset
        let visible = textView.bounds.height - inset.top - inset.bottom
        let limit = max(-inset.top, textView.contentSize.height - textView.bounds.height + inset.bottom)
        let target = min(max(y - inset.top - visible / 2, -inset.top), limit)
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

    // MARK: - Clicks

    #if canImport(AppKit)
    @objc private func handleClick(_ recognizer: NSClickGestureRecognizer) {
        let point = recognizer.location(in: textView)
        handleTap(atUTF16Index: textView.characterIndexForInsertion(at: point))
    }
    #else
    @objc private func handleTap(_ recognizer: UITapGestureRecognizer) {
        let point = recognizer.location(in: textView)
        guard let position = textView.closestPosition(to: point) else { return }
        handleTap(atUTF16Index: textView.offset(from: textView.beginningOfDocument, to: position))
    }
    #endif

    /// Routes a click to the word's cue, or to the line when it lands on
    /// whitespace or beside the words.
    private func handleTap(atUTF16Index index: Int) {
        guard let position = lineRanges.firstIndex(where: { index >= $0.location && index <= $0.location + $0.length }) else { return }
        let line = lines[position]
        let local = characterOffset(ofUTF16: index - lineRanges[position].location, in: line.text)
        guard let view else { return }
        if let cue = cue(atCharacter: local, in: line) {
            view.onWordTap(cue)
        } else {
            view.onLineTap(line)
        }
    }

    /// The cue of the word containing the character: the first cue that
    /// overlaps the whitespace-delimited word around it.
    private func cue(atCharacter position: Int, in line: LyricLine) -> LyricCue? {
        let characters = Array(line.text)
        guard position < characters.count, !characters[position].isWhitespace else { return nil }
        var start = position
        while start > 0, !characters[start - 1].isWhitespace { start -= 1 }
        var end = position
        while end < characters.count, !characters[end].isWhitespace { end += 1 }
        return line.cues.first(where: { $0.endPosition > start && $0.startPosition < end })
    }

    // MARK: - Character offsets

    /// Cue positions count characters; the storage counts UTF-16 units.
    private func utf16Offset(ofCharacter position: Int, in text: String) -> Int {
        let index = text.index(text.startIndex, offsetBy: min(position, text.count))
        return text.utf16.distance(from: text.utf16.startIndex, to: index)
    }

    private func characterOffset(ofUTF16 offset: Int, in text: String) -> Int {
        guard let utf16Index = text.utf16.index(text.utf16.startIndex, offsetBy: min(offset, text.utf16.count), limitedBy: text.utf16.endIndex),
              let index = utf16Index.samePosition(in: text)
        else { return 0 }
        return text.distance(from: text.startIndex, to: index)
    }
}

#if !canImport(AppKit)
extension TranscriptTextCoordinator: UITextViewDelegate {
    public func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
        view?.onUserScroll()
    }
}
#endif
