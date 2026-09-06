import SwiftUI
#if canImport(AppKit)
import AppKit
#else
import UIKit
#endif

/// The interface between the transcript and its controls: commands go in,
/// observable status comes out. The transcript owns its content work;
/// controls read the status and send commands without knowing anything
/// about the text.
@Observable
@MainActor
public final class TranscriptController {
    fileprivate weak var coordinator: TranscriptTextCoordinator?

    /// The position of the selected match.
    public fileprivate(set) var matchIndex = 0
    public fileprivate(set) var matchCount = 0
    /// True while a search runs in the background.
    public fileprivate(set) var isSearching = false

    public init() {}

    /// Centers the spoken word now.
    public func centerOnSpokenWord(animated: Bool) {
        coordinator?.centerOnSpokenWord(forced: true, animated: animated)
    }

    /// Steps to the next or previous match, wrapping, and centers it.
    public func stepMatch(by delta: Int) {
        coordinator?.stepMatch(by: delta)
    }
}

/// The transcript as one native text view. The text system lays the whole
/// book out lazily, answers where any character range sits, and scrolls to
/// it, so following the narration needs no view-level machinery. Word colors
/// come from a resolver of rendering attributes; recoloring re-lays the
/// spoken line, which changes no metrics.
public struct TranscriptTextView {
    let lines: [LyricLine]
    /// The book's chapters, shown as heading lines in the transcript.
    let chapters: [Chapter]
    /// The anchor the coloring and centering project the listening position
    /// from.
    let anchor: PlaybackAnchor
    /// True while the view keeps the spoken word centered.
    let isTracking: Bool
    /// False while another view covers the transcript; centering then lands
    /// without animation, since nobody can watch the glide.
    let isVisible: Bool
    /// The phrase whose occurrences color as search matches.
    let searchQuery: String
    /// True when the search matches case exactly.
    let searchIsCaseSensitive: Bool
    /// Space kept clear at the top, under the floating filter bar.
    let topInset: CGFloat
    /// Resting clearance under the last line.
    let bottomInset: CGFloat
    /// Side padding of the text.
    let horizontalPadding: CGFloat
    let controller: TranscriptController
    /// Called with the clicked word's cue.
    let onWordTap: (LyricCue) -> Void
    /// Called with the clicked chapter heading's chapter.
    let onChapterTap: (Chapter) -> Void
    /// Called when the user scrolls or navigates the transcript themselves.
    let onUserScroll: () -> Void

    public init(
        lines: [LyricLine],
        chapters: [Chapter],
        anchor: PlaybackAnchor,
        isTracking: Bool,
        isVisible: Bool,
        searchQuery: String,
        searchIsCaseSensitive: Bool,
        topInset: CGFloat,
        bottomInset: CGFloat,
        horizontalPadding: CGFloat,
        controller: TranscriptController,
        onWordTap: @escaping (LyricCue) -> Void,
        onChapterTap: @escaping (Chapter) -> Void,
        onUserScroll: @escaping () -> Void
    ) {
        self.lines = lines
        self.chapters = chapters
        self.anchor = anchor
        self.isTracking = isTracking
        self.isVisible = isVisible
        self.searchQuery = searchQuery
        self.searchIsCaseSensitive = searchIsCaseSensitive
        self.topInset = topInset
        self.bottomInset = bottomInset
        self.horizontalPadding = horizontalPadding
        self.controller = controller
        self.onWordTap = onWordTap
        self.onChapterTap = onChapterTap
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
        context.coordinator.controller = controller
        return view
    }

    public func updateNSView(_ view: NSScrollView, context: Context) {
        controller.coordinator = context.coordinator
        context.coordinator.update(from: self)
    }

    public static func dismantleNSView(_ view: NSScrollView, coordinator: TranscriptTextCoordinator) {
        coordinator.cancelTick()
        coordinator.cancelSearch()
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
        context.coordinator.controller = controller
        return view
    }

    public func updateUIView(_ view: UITextView, context: Context) {
        controller.coordinator = context.coordinator
        context.coordinator.update(from: self)
    }

    public static func dismantleUIView(_ view: UITextView, coordinator: TranscriptTextCoordinator) {
        coordinator.cancelTick()
        coordinator.cancelSearch()
    }
}
#endif

/// Owns the platform text view: builds its attributed content, recolors the
/// spoken ranges on each position update, and keeps the spoken word centered
/// while tracking is on.
@MainActor
public final class TranscriptTextCoordinator: NSObject {
    fileprivate weak var controller: TranscriptController?

    /// The view's lines as given, kept for change detection.
    private var sourceLines: [LyricLine] = []
    /// The lines on display: the source lines with one heading line per
    /// chapter.
    private var lines: [LyricLine] = []
    private var chapters: [Chapter] = []
    /// The chapter behind each heading line, keyed by the line's position in
    /// the display lines.
    private var titleChapters: [Int: Chapter] = [:]
    /// UTF-16 range of each line's text inside the storage.
    private var lineRanges: [NSRange] = []
    /// Start times of the timed lines with their array positions, in order,
    /// for binary-searching the current line.
    private var timedLines: [(start: Double, position: Int)] = []

    private var view: TranscriptTextView?
    private var currentLine: Int?
    private var spokenCueIndex: Int?
    /// UTF-16 ranges of the search matches inside the storage, in order.
    private var matchRanges: [NSRange] = []
    /// The position of the selected match.
    private var matchIndex = 0
    /// The query whose search last started, and its case sensitivity.
    private var appliedQuery = ""
    private var appliedCaseSensitive = false
    /// The query whose matches finished and painted, and its case sensitivity.
    private var completedQuery = ""
    private var completedCaseSensitive = false
    /// The plain text of the storage, snapshotted for background searching.
    private var searchText = ""
    private var searchTask: Task<Void, Never>?
    /// Invalidates the running chunked layout pass when content changes.
    private var layoutGeneration = 0
    /// The text width the full layout pass last ran at. A resize invalidates
    /// the layout, so the pass reruns to keep positions exact.
    private var laidOutWidth: CGFloat = 0
    /// The last vertical center the view scrolled to, so following scrolls
    /// once per visual line, not once per word.
    private var centeredY: CGFloat?
    /// Wakes the coordinator at the next line or cue boundary.
    private var tickTimer: Timer?

    /// How long a tracking scroll glides.
    private static let scrollDuration: TimeInterval = 0.4

    #if canImport(AppKit)
    private var scrollView: MomentumCancellingScrollView!
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

        let scrollView = MomentumCancellingScrollView()
        scrollView.documentView = textView
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.automaticallyAdjustsContentInsets = false
        self.scrollView = scrollView

        let click = NSClickGestureRecognizer(target: self, action: #selector(handleClick(_:)))
        textView.addGestureRecognizer(click)
        installColorValidator()

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
        installColorValidator()
        return textView
    }
    #endif

    deinit {
        // Owned by SwiftUI state, so deallocation happens on the main thread.
        MainActor.assumeIsolated {
            tickTimer?.invalidate()
            searchTask?.cancel()
            #if canImport(AppKit)
            if let scrollObserver {
                NotificationCenter.default.removeObserver(scrollObserver)
            }
            #endif
        }
    }

    /// Stops the boundary timer when the view leaves the hierarchy.
    func cancelTick() {
        tickTimer?.invalidate()
        tickTimer = nil
    }

    /// Stops any background search when the view leaves the hierarchy.
    func cancelSearch() {
        searchTask?.cancel()
        searchTask = nil
    }

    // MARK: - Updates

    func update(from view: TranscriptTextView) {
        // Array equality short-circuits on shared storage, so this is cheap per tick.
        let contentChanged = view.lines != sourceLines || view.chapters != chapters
        self.view = view
        applyInsets()
        if contentChanged {
            rebuildContent()
        } else if textView.bounds.width != laidOutWidth {
            startFullLayout()
        }
        if contentChanged || view.searchQuery != appliedQuery || view.searchIsCaseSensitive != appliedCaseSensitive {
            applySearch()
        }
        followPosition(recentered: contentChanged)
        scheduleNextTick()
    }

    /// The listening position the anchor projects to now.
    private func projectedPosition() -> Double {
        view?.anchor.position(at: Date()) ?? 0
    }

    /// Delay after each boundary, so the projected position covers the word.
    private static let tickSlack: TimeInterval = 0.005

    /// Schedules the wakeup for the next boundary the anchor will cross. A
    /// still anchor, or one past the last boundary, leaves no timer.
    private func scheduleNextTick() {
        tickTimer?.invalidate()
        tickTimer = nil
        guard let anchor = view?.anchor, anchor.rate > 0,
              let next = nextBoundarySeconds(after: anchor.position(at: Date())),
              let date = anchor.date(forPosition: next)
        else { return }
        let timer = Timer(fire: date.addingTimeInterval(Self.tickSlack), interval: 0, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.tick()
            }
        }
        timer.tolerance = 0
        RunLoop.main.add(timer, forMode: .common)
        tickTimer = timer
    }

    /// One wakeup: recolors for the new position and schedules the next.
    private func tick() {
        followPosition(recentered: false)
        scheduleNextTick()
    }

    /// The next moment the current line or spoken cue changes: the first cue
    /// of the current line past the position, or the next timed line's start.
    private func nextBoundarySeconds(after seconds: Double) -> Double? {
        var next: Double?
        if let currentLine, lines.indices.contains(currentLine),
           let cue = lines[currentLine].cues.first(where: { $0.startSeconds > seconds }) {
            next = cue.startSeconds
        }
        if let lineStart = nextTimedLineStart(after: seconds), lineStart < next ?? .infinity {
            next = lineStart
        }
        return next
    }

    /// The start of the first timed line strictly past the position.
    private func nextTimedLineStart(after seconds: Double) -> Double? {
        let position = timedLines.partitioningIndex { $0.start > seconds }
        return position < timedLines.count ? timedLines[position].start : nil
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
        let seconds = projectedPosition()
        let line = lineIndex(at: seconds)
        let cue = line.flatMap { spokenCueIndex(in: lines[$0], at: seconds) }
        let moved = line != currentLine || cue != spokenCueIndex
        guard moved || recentered else { return }
        let previousLine = currentLine
        currentLine = line
        spokenCueIndex = cue
        if moved {
            recolor(fromLine: previousLine, toLine: line)
        }
        if view.isTracking {
            centerOnSpokenWord(forced: recentered, animated: !recentered)
        }
    }

    /// The array position of the line containing the playback position.
    private func lineIndex(at seconds: Double) -> Int? {
        guard seconds > 0 else { return nil }
        let position = timedLines.partitioningIndex { $0.start > seconds }
        return position > 0 ? timedLines[position - 1].position : nil
    }

    /// The index of the last cue starting at or before the position.
    private func spokenCueIndex(in line: LyricLine, at seconds: Double) -> Int? {
        line.cues.lastIndex(where: { $0.startSeconds <= seconds })
    }

    /// The storage location where the current line starts, or zero without
    /// a current line.
    private func currentLineStart() -> Int {
        currentLine.flatMap { lineRanges.indices.contains($0) ? lineRanges[$0].location : nil } ?? 0
    }

    // MARK: - Content

    /// The text styles, from the platform's semantic fonts and colors so the
    /// view follows the system appearance.
    private enum Style {
        static let body: PlatformFont = .preferredFont(forTextStyle: .title2)
        static let title: PlatformFont = {
            let base = PlatformFont.preferredFont(forTextStyle: .title1)
            #if canImport(AppKit)
            return NSFontManager.shared.convert(base, toHaveTrait: .boldFontMask)
            #else
            guard let descriptor = base.fontDescriptor.withSymbolicTraits(.traitBold) else { return base }
            return UIFont(descriptor: descriptor, size: 0)
            #endif
        }()
        static let read: PlatformColor = .secondaryLabel
        static let unread: PlatformColor = .label
        static let spoken: PlatformColor = .accent
        static let match: PlatformColor = .matchHighlight

        static let paragraph: NSParagraphStyle = {
            let style = NSMutableParagraphStyle()
            style.paragraphSpacing = 4
            return style
        }()

        static let titleParagraph: NSParagraphStyle = {
            let style = NSMutableParagraphStyle()
            style.paragraphSpacing = 4
            style.paragraphSpacingBefore = 12
            return style
        }()

        static let bodyAttributes: [NSAttributedString.Key: Any] = [
            .font: body,
            .foregroundColor: unread,
            .paragraphStyle: paragraph,
        ]

        static let titleAttributes: [NSAttributedString.Key: Any] = [
            .font: title,
            .foregroundColor: unread,
            .paragraphStyle: titleParagraph,
        ]
    }

    /// Builds the storage from the lines: one paragraph per line, chapter
    /// headings in the title style, and the colors of the view's position
    /// baked in, so no recolor follows the build.
    private func rebuildContent() {
        guard let view else { return }
        sourceLines = view.lines
        chapters = view.chapters
        (lines, titleChapters) = Self.mergedLines(sourceLines, chapters: chapters)
        lineRanges = []
        timedLines = []
        matchRanges = []
        matchIndex = 0
        completedQuery = ""
        centeredY = nil

        let content = NSMutableAttributedString()
        for (position, line) in lines.enumerated() {
            let isTitle = titleChapters[position] != nil
            let attributes = isTitle ? Style.titleAttributes : Style.bodyAttributes
            let text = NSAttributedString(string: line.text + "\n", attributes: attributes)
            lineRanges.append(NSRange(location: content.length, length: (line.text as NSString).length))
            if let start = line.startSeconds {
                timedLines.append((start: start, position: position))
            }
            content.append(text)
        }
        let seconds = projectedPosition()
        currentLine = lineIndex(at: seconds)
        spokenCueIndex = currentLine.flatMap { spokenCueIndex(in: lines[$0], at: seconds) }
        storage?.setAttributedString(content)
        invalidateAllColors()
        searchText = content.string
        startFullLayout()
    }

    /// Builds the display lines: the source lines with one heading line per
    /// chapter. The transcript line at the chapter's start becomes the
    /// heading when its words are exactly the chapter's title; otherwise an
    /// untimed heading line with the title is inserted there. One walk
    /// covers both ordered lists. An empty transcript stays empty, and a
    /// transcript without timestamps gets no headings, since they have no
    /// position to land on.
    private static func mergedLines(_ lines: [LyricLine], chapters: [Chapter]) -> (lines: [LyricLine], titles: [Int: Chapter]) {
        guard lines.contains(where: { $0.startSeconds != nil }) else { return (lines, [:]) }
        var merged: [LyricLine] = []
        var titles: [Int: Chapter] = [:]
        var lineIndex = 0
        for chapter in chapters {
            while lineIndex < lines.count, (lines[lineIndex].startSeconds ?? -1) < chapter.startSeconds - Chapter.startSlackSeconds {
                merged.append(lines[lineIndex])
                lineIndex += 1
            }
            titles[merged.count] = chapter
            if lineIndex < lines.count, matchesTitle(lines[lineIndex], of: chapter) {
                merged.append(lines[lineIndex])
                lineIndex += 1
            } else {
                merged.append(headingLine(for: chapter))
            }
        }
        merged.append(contentsOf: lines[lineIndex...])
        return (merged, titles)
    }

    /// True when the line's words are exactly the chapter's title, compared
    /// without case.
    private static func matchesTitle(_ line: LyricLine, of chapter: Chapter) -> Bool {
        let lineText = line.text.trimmingCharacters(in: .whitespaces)
        let title = chapter.title.trimmingCharacters(in: .whitespaces)
        return lineText.caseInsensitiveCompare(title) == .orderedSame
    }

    /// An untimed heading line holding the chapter's title, for chapters
    /// whose title is not read aloud. With no start time and no cues, the
    /// line never becomes the current line and never highlights. The
    /// negative index keeps it apart from the source lines.
    private static func headingLine(for chapter: Chapter) -> LyricLine {
        LyricLine(index: -1 - chapter.index, text: chapter.title, startSeconds: nil, cues: [])
    }

    // MARK: - Full layout

    /// Lays the document out. On the Mac a chunked pass between run-loop
    /// turns makes every position exact, with each chunk compensated so the
    /// viewport stays put. On iOS there is no pass: heights refine as the
    /// viewport reaches them and UITextView keeps the visible text in place
    /// itself, while a background pass would slide the content under the
    /// recoloring for the pass's whole duration.
    private func startFullLayout() {
        layoutGeneration += 1
        laidOutWidth = textView.bounds.width
        #if canImport(AppKit)
        let generation = layoutGeneration
        Task { @MainActor in
            var position = 0
            while generation == self.layoutGeneration, position < self.lineRanges.count {
                self.keepingViewport {
                    self.layOutLines(from: position, count: Self.layoutChunkLines)
                    self.updateContentGeometry()
                }
                position += Self.layoutChunkLines
                await Task.yield()
            }
            guard generation == self.layoutGeneration else { return }
            if self.view?.isTracking == true {
                self.centerOnSpokenWord(forced: true, animated: false)
            }
        }
        #else
        if view?.isTracking == true {
            centerOnSpokenWord(forced: true, animated: false)
        }
        #endif
    }

    /// Lines laid out per chunk of the layout pass.
    private static let layoutChunkLines = 400

    private func layOutLines(from position: Int, count: Int) {
        let last = min(position + count, lineRanges.count) - 1
        guard position <= last,
              let layoutManager = textView.textLayoutManager,
              let contentManager = layoutManager.textContentManager,
              let textRange = textRange(from: linesRange(from: position, to: last), in: contentManager)
        else { return }
        layoutManager.ensureLayout(for: textRange)
    }

    private var storage: NSTextStorage? {
        textView.textStorage
    }

    /// Recolors the span of lines between the stored position and the given
    /// one, by marking its colors stale.
    private func recolor(fromLine previousLine: Int?, toLine line: Int?) {
        let oldLine = previousLine ?? 0
        let newLine = line ?? 0
        invalidateColors(in: linesRange(from: min(oldLine, newLine), to: max(oldLine, newLine)))
    }

    /// Installs the color resolver as the layout manager's rendering-
    /// attributes validator. Each fragment asks it for colors as the
    /// fragment lays out, so coloring lives outside the text storage and
    /// the document colors lazily.
    private func installColorValidator() {
        textView.textLayoutManager?.renderingAttributesValidator = { [weak self] layoutManager, fragment in
            MainActor.assumeIsolated {
                self?.validateColors(of: fragment, in: layoutManager)
            }
        }
    }

    /// Paints one fragment's final colors through the resolver.
    private func validateColors(of fragment: NSTextLayoutFragment, in layoutManager: NSTextLayoutManager) {
        guard let contentManager = layoutManager.textContentManager else { return }
        let element = fragment.rangeInElement
        let location = contentManager.offset(from: contentManager.documentRange.location, to: element.location)
        let length = contentManager.offset(from: element.location, to: element.endLocation)
        repaintResolved(NSRange(location: location, length: length))
    }

    /// Recolors the range: its rendering attributes revert to the resolver,
    /// and the redraw nudge makes its fragments re-ask it now.
    private func invalidateColors(in range: NSRange) {
        guard let layoutManager = textView.textLayoutManager,
              let contentManager = layoutManager.textContentManager,
              let textRange = textRange(from: range, in: contentManager)
        else { return }
        layoutManager.invalidateRenderingAttributes(for: textRange)
        nudgeRedraw(of: textRange, in: layoutManager)
    }

    /// Marks the whole document's colors stale and refreshes the visible
    /// part now. Fragments outside the viewport revalidate as they lay out.
    private func invalidateAllColors() {
        guard let layoutManager = textView.textLayoutManager else { return }
        layoutManager.invalidateRenderingAttributes(for: layoutManager.documentRange)
        guard let viewport = layoutManager.textViewportLayoutController.viewportRange else { return }
        nudgeRedraw(of: viewport, in: layoutManager)
    }

    /// Re-lays the range's fragments through a zero-length attribute edit,
    /// the one path the view reliably redraws from, then re-lays the range
    /// and pushes its geometry in the same turn, so no estimated heights
    /// linger for the view's own bookkeeping to react to. Colors change no
    /// metrics, so the geometry comes back identical and the content stays
    /// in place.
    private func nudgeRedraw(of textRange: NSTextRange, in layoutManager: NSTextLayoutManager) {
        guard let storage,
              let contentManager = layoutManager.textContentManager
        else { return }
        let location = contentManager.offset(from: contentManager.documentRange.location, to: textRange.location)
        let length = contentManager.offset(from: textRange.location, to: textRange.endLocation)
        guard length > 0 else { return }
        storage.beginEditing()
        storage.edited(.editedAttributes, range: NSRange(location: location, length: length), changeInLength: 0)
        storage.endEditing()
        layoutManager.ensureLayout(for: textRange)
        updateContentGeometry()
    }

    /// Runs the work, then shifts the scroll so the text at the top of the
    /// viewport keeps its place on screen when the work moved the content.
    /// Only the Mac needs the shift: UITextView adjusts its own offset when
    /// the geometry above the viewport changes, and a manual shift there
    /// would double the move.
    private func keepingViewport(_ work: () -> Void) {
        #if canImport(AppKit)
        let anchor = viewportAnchorRange()
        let before = anchor.flatMap { frame(forStorageRange: $0)?.minY }
        work()
        guard let anchor, let before, let after = frame(forStorageRange: anchor)?.minY else { return }
        shiftScroll(by: after - before)
        #else
        work()
        #endif
    }

    /// A zero-length range at the start of the text at the current scroll
    /// offset, whose frame anchors offset corrections. Asked of the layout
    /// manager directly: the render viewport lags programmatic scrolls, so
    /// anchoring on it corrects against the wrong text.
    private func viewportAnchorRange() -> NSRange? {
        guard let layoutManager = textView.textLayoutManager,
              let contentManager = layoutManager.textContentManager
        else { return nil }
        #if canImport(AppKit)
        let offsetY = scrollView.contentView.bounds.origin.y - textView.textContainerOrigin.y
        #else
        let offsetY = textView.contentOffset.y - textView.textContainerInset.top
        #endif
        guard let fragment = layoutManager.textLayoutFragment(for: CGPoint(x: 0, y: max(0, offsetY))) else { return nil }
        let start = contentManager.offset(from: contentManager.documentRange.location, to: fragment.rangeInElement.location)
        return NSRange(location: start, length: 0)
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

    /// Paints the range's final colors: the positional base, then the
    /// matches, clipped against the spoken cue so the spoken word wins.
    private func repaintResolved(_ range: NSRange) {
        for segment in baseSegments(for: range) {
            paint(segment.color, range: segment.range)
        }
        repaintMatches(intersecting: range)
    }

    /// The positional color runs over the range, in paint order: the read
    /// region, the unread region, and the current line's runs on top.
    private func baseSegments(for range: NSRange) -> [(color: PlatformColor, range: NSRange)] {
        var segments: [(color: PlatformColor, range: NSRange)] = []
        let readEnd = currentLineStart()
        let end = range.location + range.length
        if readEnd > range.location {
            segments.append((Style.read, NSRange(location: range.location, length: min(readEnd, end) - range.location)))
        }
        let unreadStart = max(readEnd, range.location)
        if end > unreadStart {
            segments.append((Style.unread, NSRange(location: unreadStart, length: end - unreadStart)))
        }
        if let currentLine, lineRanges.indices.contains(currentLine),
           NSIntersectionRange(range, lineRanges[currentLine]).length > 0 {
            segments += spokenLineSegments(currentLine, cue: spokenCueIndex)
        }
        return segments
    }

    /// The color runs of the given line, in paint order: the whole line
    /// unread, then its read part and spoken cue on top.
    private func spokenLineSegments(_ line: Int, cue: Int?) -> [(color: PlatformColor, range: NSRange)] {
        let range = lineRanges[line]
        var segments: [(color: PlatformColor, range: NSRange)] = [(Style.unread, range)]
        guard let cue else { return segments }
        let spoken = lines[line].cues[cue]
        let readEnd = utf16Offset(ofCharacter: spoken.startPosition, in: lines[line].text)
        if readEnd > 0 {
            segments.append((Style.read, NSRange(location: range.location, length: readEnd)))
        }
        if let cueRange = spokenCueRange(line, cue: cue) {
            segments.append((Style.spoken, cueRange))
        }
        return segments
    }

    /// The storage range of the given line's spoken cue.
    private func spokenCueRange(_ line: Int?, cue: Int?) -> NSRange? {
        guard let line, let cue, lineRanges.indices.contains(line) else { return nil }
        let spoken = lines[line].cues[cue]
        let text = lines[line].text
        let readEnd = utf16Offset(ofCharacter: spoken.startPosition, in: text)
        let spokenEnd = utf16Offset(ofCharacter: spoken.endPosition, in: text)
        guard spokenEnd > readEnd else { return nil }
        return NSRange(location: lineRanges[line].location + readEnd, length: spokenEnd - readEnd)
    }

    /// Applies one color edit, as a rendering attribute on the layout
    /// manager. Rendering attributes change drawing only, so a paint never
    /// invalidates layout and never moves the content.
    private func paint(_ color: PlatformColor, range: NSRange) {
        guard range.length > 0,
              let layoutManager = textView.textLayoutManager,
              let contentManager = layoutManager.textContentManager,
              let textRange = textRange(from: range, in: contentManager)
        else { return }
        layoutManager.addRenderingAttribute(.foregroundColor, value: color, for: textRange)
    }

    /// The storage range spanning the given line positions, clamped to the
    /// known lines.
    private func linesRange(from low: Int, to high: Int) -> NSRange {
        guard let first = lineRanges.indices.contains(low) ? lineRanges[low] : lineRanges.first,
              let last = lineRanges.indices.contains(high) ? lineRanges[high] : lineRanges.last
        else { return NSRange(location: 0, length: 0) }
        return NSRange(location: first.location, length: last.location + last.length - first.location)
    }

    // MARK: - Search

    /// Starts a background search for the view's query, restarting any
    /// search underway. A blank query clears the matches directly.
    private func applySearch() {
        guard let view else { return }
        let query = view.searchQuery
        let caseSensitive = view.searchIsCaseSensitive
        appliedQuery = query
        appliedCaseSensitive = caseSensitive
        searchTask?.cancel()
        searchTask = nil
        guard !query.isEmpty else {
            if !matchRanges.isEmpty {
                matchRanges = []
                invalidateAllColors()
            }
            matchIndex = 0
            completedQuery = ""
            setSearching(false)
            publishMatchState()
            return
        }
        setSearching(true)
        let text = searchText
        // A result that hit the match limit covers only the document's start,
        // so narrowing from it would lose every match past the cutoff. A
        // result of a different sensitivity does not contain this search's
        // match starts at all.
        let narrowing = matchRanges.isEmpty || matchRanges.count >= Self.matchLimit || completedCaseSensitive != caseSensitive
            ? nil
            : (query: completedQuery, ranges: matchRanges)
        searchTask = Task.detached(priority: .userInitiated) { [weak self] in
            let ranges = Self.findMatches(of: query, in: text, caseSensitive: caseSensitive, narrowingFrom: narrowing)
            guard !Task.isCancelled else { return }
            await MainActor.run { [weak self] in
                self?.finishSearch(query: query, caseSensitive: caseSensitive, ranges: ranges)
            }
        }
    }

    /// Installs a finished search: the old match colors revert, the new
    /// matches paint in one batch, and a fresh query lands on the first
    /// match at or past the spoken line.
    private func finishSearch(query: String, caseSensitive: Bool, ranges: [NSRange]) {
        guard query == appliedQuery, caseSensitive == appliedCaseSensitive else { return }
        let isFreshQuery = query != completedQuery || caseSensitive != completedCaseSensitive
        // With no matches before or after there is nothing to repaint.
        if !matchRanges.isEmpty || !ranges.isEmpty {
            matchRanges = ranges
            invalidateAllColors()
        }
        completedQuery = query
        completedCaseSensitive = caseSensitive
        if isFreshQuery {
            matchIndex = nearestForwardMatch()
            if !ranges.isEmpty {
                center(onStorageRange: ranges[matchIndex], forced: true, animated: true)
                view?.onUserScroll()
            }
        } else {
            matchIndex = min(matchIndex, max(0, ranges.count - 1))
        }
        setSearching(false)
        publishMatchState()
    }

    /// Steps to the next or previous match, wrapping, and centers it.
    func stepMatch(by delta: Int) {
        let count = matchRanges.count
        guard count > 0 else { return }
        matchIndex = ((matchIndex + delta) % count + count) % count
        center(onStorageRange: matchRanges[matchIndex], forced: true, animated: true)
        view?.onUserScroll()
        publishMatchState()
    }

    /// The position of the first match at or after the spoken line, wrapping
    /// to the first match overall.
    private func nearestForwardMatch() -> Int {
        guard !matchRanges.isEmpty else { return 0 }
        let location = currentLineStart()
        let position = matchRanges.partitioningIndex { $0.location >= location }
        return position < matchRanges.count ? position : 0
    }

    /// Upper bound on collected matches, so a one-letter query stays fast.
    nonisolated private static let matchLimit = 10_000

    /// Every occurrence of the query in the text, in order, up to the match
    /// limit. When the finished previous query is a prefix of this one, only
    /// the previous match starts are tested.
    nonisolated private static func findMatches(of query: String, in text: String, caseSensitive: Bool, narrowingFrom previous: (query: String, ranges: [NSRange])?) -> [NSRange] {
        let full = text as NSString
        guard let previous, !previous.query.isEmpty,
              extends(previous.query, to: query, caseSensitive: caseSensitive)
        else {
            return findOccurrences(of: query, in: full, caseSensitive: caseSensitive, limit: matchLimit) { Task.isCancelled }
        }
        let options = searchCompareOptions(caseSensitive: caseSensitive).union(.anchored)
        var ranges: [NSRange] = []
        for candidate in previous.ranges {
            let remaining = NSRange(location: candidate.location, length: full.length - candidate.location)
            let match = full.range(of: query, options: options, range: remaining, locale: searchLocale)
            if match.location != NSNotFound {
                ranges.append(match)
                if ranges.count >= matchLimit { break }
            }
        }
        return ranges
    }

    /// True when the new query extends the old, so every new match starts at
    /// an old match's start.
    nonisolated private static func extends(_ old: String, to new: String, caseSensitive: Bool) -> Bool {
        caseSensitive ? new.hasPrefix(old) : new.lowercased().hasPrefix(old.lowercased())
    }

    /// Published outside the SwiftUI update this can run in.
    private func setSearching(_ searching: Bool) {
        Task { @MainActor in self.controller?.isSearching = searching }
    }

    /// Published outside the SwiftUI update this can run in.
    private func publishMatchState() {
        let index = matchIndex
        let count = matchRanges.count
        Task { @MainActor in
            self.controller?.matchIndex = index
            self.controller?.matchCount = count
        }
    }

    /// Repaints the match color over the occurrences intersecting the range.
    private func repaintMatches(intersecting range: NSRange) {
        guard !matchRanges.isEmpty else { return }
        let cue = spokenCueRange(currentLine, cue: spokenCueIndex)
        var position = matchRanges.partitioningIndex { $0.location + $0.length > range.location }
        while position < matchRanges.count, matchRanges[position].location < range.location + range.length {
            paintMatch(matchRanges[position], clippedBy: cue)
            position += 1
        }
    }

    /// Paints the match color over the range, minus the cue.
    private func paintMatch(_ match: NSRange, clippedBy cue: NSRange?) {
        guard let cue else {
            paint(Style.match, range: match)
            return
        }
        let end = match.location + match.length
        let cueEnd = cue.location + cue.length
        if cue.location > match.location {
            paint(Style.match, range: NSRange(location: match.location, length: min(cue.location, end) - match.location))
        }
        if end > cueEnd {
            let start = max(cueEnd, match.location)
            paint(Style.match, range: NSRange(location: start, length: end - start))
        }
    }

    // MARK: - Centering

    /// Scrolls the spoken word's visual line to the viewport's center. The
    /// unforced form skips targets on the already-centered visual line, so
    /// tracking steps once per line of text.
    func centerOnSpokenWord(forced: Bool, animated: Bool) {
        guard let range = spokenTargetRange() else { return }
        center(onStorageRange: range, forced: forced, animated: animated)
    }

    /// Scrolls the range's visual line to the viewport's center, unless it
    /// is centered already. The corridor between the viewport and the target
    /// lays out first, so the measured distance to the target is exact even
    /// where estimated heights elsewhere are not.
    private func center(onStorageRange range: NSRange, forced: Bool, animated: Bool) {
        layOutCorridor(to: range)
        guard let targetY = frame(forStorageRange: range)?.midY else { return }
        if !forced, let centeredY, abs(targetY - centeredY) <= 1 { return }
        centeredY = targetY
        scroll(toCenterY: targetY, animated: animated && view?.isVisible != false)
    }

    /// Lays out everything between the viewport and the target, keeping the
    /// viewport's text in place when refinement above it moves the content.
    private func layOutCorridor(to target: NSRange) {
        guard let layoutManager = textView.textLayoutManager,
              let contentManager = layoutManager.textContentManager,
              let anchor = viewportAnchorRange()
        else { return }
        let start = min(anchor.location, target.location)
        let end = max(anchor.location, target.location + target.length)
        guard let corridor = textRange(from: NSRange(location: start, length: end - start), in: contentManager) else { return }
        keepingViewport {
            layoutManager.ensureLayout(for: corridor)
            updateContentGeometry()
        }
    }

    /// Pushes the laid-out extent into the view, so the scroll limit and
    /// the clip constraint see the corridor's true size right away instead
    /// of the stale document height.
    private func updateContentGeometry() {
        #if canImport(AppKit)
        textView.needsLayout = true
        textView.layoutSubtreeIfNeeded()
        #else
        textView.layoutIfNeeded()
        #endif
    }

    /// The range's frame in text view coordinates, from the layout.
    private func frame(forStorageRange range: NSRange) -> CGRect? {
        guard let layoutManager = textView.textLayoutManager,
              let contentManager = layoutManager.textContentManager,
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
    /// between the insets. Leftover momentum from a user scroll dies here,
    /// so it cannot pull the view off the target afterwards.
    private func scroll(toCenterY y: CGFloat, animated: Bool) {
        guard let view else { return }
        #if canImport(AppKit)
        scrollView.dropsMomentum = true
        let clip = scrollView.contentView
        let target = scrollTarget(centering: y, viewportHeight: clip.bounds.height, topInset: view.topInset, bottomInset: view.bottomInset)
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
        let limit = max(-topInset, documentHeight() - viewportHeight + bottomInset)
        return min(max(y - topInset - visible / 2, -topInset), limit)
    }

    private func documentHeight() -> CGFloat {
        guard let layoutManager = textView.textLayoutManager else {
            #if canImport(AppKit)
            return textView.frame.height
            #else
            return textView.contentSize.height
            #endif
        }
        return layoutManager.usageBoundsForTextContainer.height
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

    /// Routes a click: anywhere on a chapter heading goes to the chapter,
    /// and a word elsewhere goes to its cue. Clicks on whitespace or beside
    /// the words of a body line do nothing.
    private func handleTap(atUTF16Index index: Int) {
        guard let view else { return }
        let position = lineRanges.partitioningIndex { $0.location + $0.length >= index }
        guard position < lineRanges.count, index >= lineRanges[position].location else { return }
        if let chapter = titleChapters[position] {
            view.onChapterTap(chapter)
            return
        }
        let line = lines[position]
        let local = characterOffset(ofUTF16: index - lineRanges[position].location, in: line.text)
        guard let cue = cue(atCharacter: local, in: line) else { return }
        view.onWordTap(cue)
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

extension Array {
    /// The position of the first element in the suffix the predicate marks,
    /// or the count when the suffix is empty, by binary search. The array
    /// must order all non-matching elements before all matching ones.
    fileprivate func partitioningIndex(where belongsToSuffix: (Element) -> Bool) -> Int {
        var low = 0
        var high = count
        while low < high {
            let mid = (low + high) / 2
            if belongsToSuffix(self[mid]) {
                high = mid
            } else {
                low = mid + 1
            }
        }
        return low
    }
}

#if !canImport(AppKit)
extension TranscriptTextCoordinator: UITextViewDelegate {
    public func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
        view?.onUserScroll()
    }
}
#else
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
