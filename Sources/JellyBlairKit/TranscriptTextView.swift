import SwiftUI
#if canImport(AppKit)
import AppKit
#else
import UIKit
#endif

/// The transcript's outward face: commands in, observable status out. The
/// transcript owns its content work; controls read the status and send
/// commands without knowing anything about the text.
@Observable
@MainActor
public final class TranscriptController {
    fileprivate weak var coordinator: TranscriptTextCoordinator?

    /// The position of the match the navigation stands on.
    public fileprivate(set) var matchIndex = 0
    public fileprivate(set) var matchCount = 0
    /// True while a search runs in the background.
    public fileprivate(set) var isSearching = false
    /// True while the full layout pass runs.
    public fileprivate(set) var isPreparingLayout = false

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
/// update as attribute edits on the spoken ranges.
public struct TranscriptTextView {
    let lines: [LyricLine]
    /// The book's chapters, for styling their heading lines.
    let chapters: [Chapter]
    /// The playback position the coloring and centering follow.
    let positionSeconds: Double
    /// True while the view keeps the spoken word centered.
    let isTracking: Bool
    /// False while another view covers the transcript; centering then lands
    /// without animation, since nobody can watch the glide.
    let isVisible: Bool
    /// The phrase whose occurrences color as search matches.
    let searchQuery: String
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
    /// Called when the user scrolls or navigates the transcript themselves.
    let onUserScroll: () -> Void

    public init(
        lines: [LyricLine],
        chapters: [Chapter],
        positionSeconds: Double,
        isTracking: Bool,
        isVisible: Bool,
        searchQuery: String,
        topInset: CGFloat,
        bottomInset: CGFloat,
        horizontalPadding: CGFloat,
        controller: TranscriptController,
        onWordTap: @escaping (LyricCue) -> Void,
        onLineTap: @escaping (LyricLine) -> Void,
        onUserScroll: @escaping () -> Void
    ) {
        self.lines = lines
        self.chapters = chapters
        self.positionSeconds = positionSeconds
        self.isTracking = isTracking
        self.isVisible = isVisible
        self.searchQuery = searchQuery
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
        context.coordinator.controller = controller
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
        context.coordinator.controller = controller
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
    fileprivate weak var controller: TranscriptController?

    private var lines: [LyricLine] = []
    private var chapters: [Chapter] = []
    /// Indices of lines drawn as chapter headings, derived from the chapters.
    private var titleLineIndices: Set<Int> = []
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
    /// The position of the match the navigation stands on.
    private var matchIndex = 0
    /// The query whose search last started.
    private var appliedQuery = ""
    /// The query whose matches finished and painted.
    private var completedQuery = ""
    /// The plain text of the storage, snapshotted for background searching.
    private var searchText = ""
    private var searchTask: Task<Void, Never>?
    /// True once the whole document is laid out, so positions are exact.
    private var isFullyLaidOut = false
    /// Invalidates the running chunked layout pass when content changes.
    private var layoutGeneration = 0
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
        let contentChanged = view.lines != lines || view.chapters != chapters
        self.view = view
        applyInsets()
        if contentChanged {
            rebuildContent()
        }
        if contentChanged || view.searchQuery != appliedQuery {
            applySearch()
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
        if moved {
            recolor(fromLine: previousLine, toLine: line, cue: cue)
        }
        if view.isTracking {
            centerOnSpokenWord(forced: recentered, animated: !recentered)
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
        static var match: PlatformColor { .matchHighlight }

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
        chapters = view.chapters
        titleLineIndices = Self.titleLineIndices(of: lines, chapters: chapters)
        lineRanges = []
        timedLines = []
        matchRanges = []
        matchIndex = 0
        completedQuery = ""
        currentLine = nil
        spokenCueIndex = nil
        centeredY = nil

        let content = NSMutableAttributedString()
        for (position, line) in lines.enumerated() {
            let isTitle = titleLineIndices.contains(line.index)
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
        searchText = content.string
        startFullLayout()
    }

    /// Indices of transcript lines that are chapter headings: the first line
    /// at a chapter's start whose words are exactly the chapter's title,
    /// compared without case. One walk covers both ordered lists.
    private static func titleLineIndices(of lines: [LyricLine], chapters: [Chapter]) -> Set<Int> {
        var indices: Set<Int> = []
        var lineIndex = 0
        for chapter in chapters {
            while lineIndex < lines.count, (lines[lineIndex].startSeconds ?? -1) < chapter.startSeconds - 0.5 {
                lineIndex += 1
            }
            guard lineIndex < lines.count else { break }
            let line = lines[lineIndex]
            let lineText = line.text.trimmingCharacters(in: .whitespaces)
            let title = chapter.title.trimmingCharacters(in: .whitespaces)
            if lineText.caseInsensitiveCompare(title) == .orderedSame {
                indices.insert(line.index)
            }
        }
        return indices
    }

    // MARK: - Full layout

    /// Lays the document out in chunks between run-loop turns, so opening a
    /// long transcript never blocks. Once every position is exact, reports
    /// completion and recenters.
    private func startFullLayout() {
        layoutGeneration += 1
        let generation = layoutGeneration
        isFullyLaidOut = false
        setPreparingLayout(true)
        Task { @MainActor in
            var position = 0
            while generation == self.layoutGeneration, position < self.lineRanges.count {
                self.layOutLines(from: position, count: Self.layoutChunkLines)
                position += Self.layoutChunkLines
                await Task.yield()
            }
            guard generation == self.layoutGeneration else { return }
            self.isFullyLaidOut = true
            self.setPreparingLayout(false)
            if self.view?.isTracking == true {
                self.centerOnSpokenWord(forced: true, animated: false)
            }
        }
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

    /// Re-settles the whole document's layout. Nearly free while the full
    /// pass has completed and little has been invalidated since.
    private func ensureFullLayout() {
        guard let layoutManager = textView.textLayoutManager,
              let contentManager = layoutManager.textContentManager
        else { return }
        layoutManager.ensureLayout(for: contentManager.documentRange)
    }

    /// Published outside the SwiftUI update this can run in.
    private func setPreparingLayout(_ preparing: Bool) {
        Task { @MainActor in self.controller?.isPreparingLayout = preparing }
    }

    private var storage: NSTextStorage? {
        textView.textStorage
    }

    /// Recolors from the stored line and cue to the given ones: whole lines
    /// take their read or unread color, and the current line colors its read
    /// part, spoken cue, and unread rest. Search matches repaint on top.
    private func recolor(fromLine previousLine: Int?, toLine line: Int?, cue: Int?) {
        guard let storage else { return }
        let oldLine = previousLine ?? 0
        let newLine = line ?? 0
        let low = min(oldLine, newLine)
        let high = max(oldLine, newLine)
        let span = linesRange(from: low, to: high)
        // Every crossed line lands on the same side of the new line, so one
        // edit covers the span; the new line itself repaints separately.
        let color = line == high ? Style.read : Style.unread
        storage.beginEditing()
        storage.addAttribute(.foregroundColor, value: color, range: span)
        paintSpokenLine(line, cue: cue)
        repaintMatches(intersecting: span)
        storage.endEditing()
    }

    /// Colors the given line's read part, spoken cue, and unread rest.
    private func paintSpokenLine(_ line: Int?, cue: Int?) {
        guard let storage, let line, lineRanges.indices.contains(line) else { return }
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
        appliedQuery = query
        searchTask?.cancel()
        searchTask = nil
        guard !query.isEmpty else {
            if !matchRanges.isEmpty {
                storage?.beginEditing()
                unpaintMatches(matchRanges)
                storage?.endEditing()
                matchRanges = []
            }
            matchIndex = 0
            completedQuery = ""
            setSearching(false)
            publishMatchState()
            return
        }
        setSearching(true)
        let text = searchText
        let narrowing = matchRanges.isEmpty ? nil : (query: completedQuery, ranges: matchRanges)
        searchTask = Task.detached(priority: .userInitiated) { [weak self] in
            let ranges = Self.findMatches(of: query, in: text, narrowingFrom: narrowing)
            guard !Task.isCancelled else { return }
            await MainActor.run { [weak self] in
                self?.finishSearch(query: query, ranges: ranges)
            }
        }
    }

    /// Installs a finished search: the old match colors revert, the new
    /// matches paint in one batch, and a fresh query lands on the first
    /// match at or past the spoken line, like find starting from a cursor.
    private func finishSearch(query: String, ranges: [NSRange]) {
        guard query == appliedQuery, let storage else { return }
        let isFreshQuery = query != completedQuery
        storage.beginEditing()
        unpaintMatches(matchRanges)
        matchRanges = ranges
        for range in ranges {
            storage.addAttribute(.foregroundColor, value: Style.match, range: range)
        }
        storage.endEditing()
        completedQuery = query
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
        let location = currentLine.flatMap { lineRanges.indices.contains($0) ? lineRanges[$0].location : nil } ?? 0
        var low = 0
        var high = matchRanges.count
        while low < high {
            let mid = (low + high) / 2
            if matchRanges[mid].location < location {
                low = mid + 1
            } else {
                high = mid
            }
        }
        return low < matchRanges.count ? low : 0
    }

    /// Restores positional colors over the lines holding the given ranges.
    private func unpaintMatches(_ ranges: [NSRange]) {
        guard let storage, !ranges.isEmpty else { return }
        var lastLine = -1
        for range in ranges {
            let line = lineIndex(containing: range.location)
            guard line != lastLine, lineRanges.indices.contains(line) else { continue }
            lastLine = line
            let read = currentLine.map { line < $0 } ?? false
            storage.addAttribute(.foregroundColor, value: read ? Style.read : Style.unread, range: lineRanges[line])
        }
        paintSpokenLine(currentLine, cue: spokenCueIndex)
    }

    /// The position of the line containing the storage location.
    private func lineIndex(containing location: Int) -> Int {
        var low = 0
        var high = lineRanges.count
        while low < high {
            let mid = (low + high) / 2
            if lineRanges[mid].location <= location {
                low = mid + 1
            } else {
                high = mid
            }
        }
        return low - 1
    }

    /// Upper bound on collected matches, so a one-letter query stays fast.
    nonisolated private static let matchLimit = 10_000

    /// Every occurrence of the query in the text, in order, up to the match
    /// limit. When the finished previous query is a prefix of this one, only
    /// the previous match starts are tested.
    nonisolated private static func findMatches(of query: String, in text: String, narrowingFrom previous: (query: String, ranges: [NSRange])?) -> [NSRange] {
        let full = text as NSString
        var ranges: [NSRange] = []
        if let previous, !previous.query.isEmpty,
           query.lowercased().hasPrefix(previous.query.lowercased()) {
            for candidate in previous.ranges {
                let remaining = NSRange(location: candidate.location, length: full.length - candidate.location)
                let match = full.range(of: query, options: [.caseInsensitive, .anchored], range: remaining)
                if match.location != NSNotFound {
                    ranges.append(match)
                    if ranges.count >= matchLimit { break }
                }
            }
            return ranges
        }
        var start = 0
        var steps = 0
        while start < full.length {
            let range = full.range(of: query, options: .caseInsensitive, range: NSRange(location: start, length: full.length - start))
            guard range.location != NSNotFound else { break }
            ranges.append(range)
            if ranges.count >= matchLimit { break }
            start = range.location + max(range.length, 1)
            steps += 1
            if steps % 512 == 0, Task.isCancelled { break }
        }
        return ranges
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

    /// Repaints the match color over the occurrences intersecting the range,
    /// found by binary search.
    private func repaintMatches(intersecting range: NSRange) {
        guard let storage, !matchRanges.isEmpty else { return }
        var low = 0
        var high = matchRanges.count
        while low < high {
            let mid = (low + high) / 2
            if matchRanges[mid].location + matchRanges[mid].length <= range.location {
                low = mid + 1
            } else {
                high = mid
            }
        }
        while low < matchRanges.count, matchRanges[low].location < range.location + range.length {
            storage.addAttribute(.foregroundColor, value: Style.match, range: matchRanges[low])
            low += 1
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
    /// is centered already. The full-layout pass keeps the measurement exact
    /// even far into unvisited text.
    private func center(onStorageRange range: NSRange, forced: Bool, animated: Bool) {
        if isFullyLaidOut {
            ensureFullLayout()
        }
        guard let targetY = frame(forStorageRange: range)?.midY else { return }
        if !forced, let centeredY, abs(targetY - centeredY) <= 1 { return }
        centeredY = targetY
        scroll(toCenterY: targetY, animated: animated && view?.isVisible != false)
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
