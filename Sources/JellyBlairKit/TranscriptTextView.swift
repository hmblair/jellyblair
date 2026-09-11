// The transcript never trusts an estimated position it is about to show.
// Lines are measured lazily in one contiguous window around the reader,
// through the one shared TextKit stack that also draws and hit-tests them,
// so a measured height is exactly a drawn height. Positions inside the
// window are exact relative to each other, which is what exact centering
// needs; lines far outside it stand at the average measured height, which
// only sways the scroll bar. Every window change reports how far it moved
// the content, and the viewport shifts the scroll with it, so the screen
// never jumps.
//
// The concerns split into components with one owner each:
// TranscriptContent (the pure text model), TranscriptLineRenderer (the one
// text engine), TranscriptLineMetrics (heights and positions),
// TranscriptLinePainter (colors), TranscriptSearchModel (matches),
// TranscriptViewport (the scroll container and the visible line views),
// and TranscriptScroller (centering scrolls).
// The coordinator below only orchestrates: it tracks the playback position
// and wires view events to the components.

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

/// The transcript as a virtualized line view: only the lines on screen
/// exist as views, and only the lines near the reader are measured, so
/// opening a book and resizing the window cost the visible band, not the
/// whole document. Word colors are painted per line by a resolver;
/// recoloring redraws the affected lines and never moves the content.
public struct TranscriptTextView {
    let lines: [LyricLine]
    /// The book's chapters, shown as heading lines in the transcript.
    let chapters: [Chapter]
    /// The anchor the coloring and centering project the listening position
    /// from.
    let anchor: PlaybackAnchor
    /// True while the view keeps the spoken word centered.
    let isTracking: Bool
    /// False while another view covers the transcript. The boundary ticks
    /// stop, and a centering that does land does so without animation,
    /// since nobody can watch the glide.
    let isVisible: Bool
    /// False while the scene is inactive, such as behind a locked screen
    /// during background playback. The boundary ticks stop with it.
    let isSceneActive: Bool
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
        isSceneActive: Bool,
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
        self.isSceneActive = isSceneActive
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
        controller.coordinator = context.coordinator
        context.coordinator.controller = controller
        return context.coordinator.scrollView
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

    public func makeUIView(context: Context) -> UIScrollView {
        controller.coordinator = context.coordinator
        context.coordinator.controller = controller
        return context.coordinator.scrollView
    }

    public func updateUIView(_ view: UIScrollView, context: Context) {
        controller.coordinator = context.coordinator
        context.coordinator.update(from: self)
    }

    public static func dismantleUIView(_ view: UIScrollView, coordinator: TranscriptTextCoordinator) {
        coordinator.cancelTick()
        coordinator.cancelSearch()
    }
}
#endif

/// Orchestrates the transcript components: tracks the playback position,
/// pushes state into the painter, and routes view events to the search
/// model and the scroller.
@MainActor
public final class TranscriptTextCoordinator: NSObject {
    fileprivate weak var controller: TranscriptController?

    private var view: TranscriptTextView?
    /// The text model on display.
    private var content = TranscriptContent(sourceLines: [], chapters: [])
    private var currentLine: Int?
    private var spokenCue: SpokenCue?
    /// The anchor's requested position, which the colors depend on.
    private var requestedSeconds: Double = 0

    private let searchModel = TranscriptSearchModel()
    private let viewport = TranscriptViewport()

    /// Wakes the coordinator at the next line or cue boundary.
    private var tickTimer: Timer?

    /// The tick gate's value at the last update, so the update that
    /// reopens it runs one forced catch-up.
    private var couldTick = false

    /// The insets last applied, so the per-tick update skips the setters.
    private var appliedInsets: (top: CGFloat, bottom: CGFloat, horizontal: CGFloat)?

    var scrollView: PlatformScrollView {
        viewport.scrollView
    }

    override init() {
        super.init()
        wireSearchModel()
        viewport.onUserScroll = { [weak self] in
            self?.view?.onUserScroll()
        }
        viewport.onTap = { [weak self] index in
            self?.handleTap(atUTF16Index: index)
        }
        // The first real width and every width change re-lay the visible
        // lines; tracking recenters on the new geometry.
        viewport.onWidthChange = { [weak self] in
            self?.followPosition(recentered: true)
        }
    }

    /// Points the search model's callbacks at this coordinator.
    private func wireSearchModel() {
        searchModel.readStart = { [weak self] in
            guard let self else { return 0 }
            return self.content.lineStart(of: self.currentLine)
        }
        searchModel.onSearchingChanged = { [weak self] searching in
            self?.setSearching(searching)
        }
        searchModel.onFinish = { [weak self] outcome in
            self?.installSearchOutcome(outcome)
        }
    }

    deinit {
        // Owned by SwiftUI state, so deallocation happens on the main thread.
        MainActor.assumeIsolated {
            tickTimer?.invalidate()
            searchModel.cancel()
        }
    }

    /// Stops the boundary timer when the view leaves the hierarchy.
    func cancelTick() {
        tickTimer?.invalidate()
        tickTimer = nil
    }

    /// Stops any background search when the view leaves the hierarchy.
    func cancelSearch() {
        searchModel.cancel()
    }

    // MARK: - Updates

    func update(from view: TranscriptTextView) {
        // Array equality short-circuits on shared storage, so this is cheap per tick.
        let contentChanged = view.lines != content.sourceLines || view.chapters != content.chapters
        self.view = view
        applyInsets()
        if contentChanged {
            rebuildContent()
        }
        if contentChanged || view.searchQuery != searchModel.appliedQuery || view.searchIsCaseSensitive != searchModel.appliedCaseSensitive {
            searchModel.apply(query: view.searchQuery, caseSensitive: view.searchIsCaseSensitive, text: content.plainText)
        }
        // Waking catches up in one step: the display state the skipped
        // ticks would have maintained projects from the anchor.
        let woke = canTick && !couldTick
        couldTick = canTick
        followPosition(recentered: contentChanged || woke)
        scheduleNextTick()
    }

    /// True while a boundary tick has an audience: the scene is active
    /// and the pane is visible. No other state needs ticks, because the
    /// position projects from the anchor and one catch-up on waking
    /// rebuilds the display.
    private var canTick: Bool {
        guard let view else { return false }
        return view.isSceneActive && view.isVisible
    }

    /// The listening position the anchor projects to now.
    private func projectedPosition() -> Double {
        view?.anchor.position(at: Date()) ?? 0
    }

    /// Delay after each boundary, so the projected position covers the word.
    private static let tickSlack: TimeInterval = 0.005

    /// Schedules the wakeup for the next boundary the anchor will cross.
    /// A closed tick gate, a still anchor, or one past the last boundary
    /// leaves no timer.
    private func scheduleNextTick() {
        tickTimer?.invalidate()
        tickTimer = nil
        guard canTick else { return }
        guard let anchor = view?.anchor, anchor.rate > 0,
              let next = content.nextBoundarySeconds(after: anchor.position(at: Date()), currentLine: currentLine),
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

    private func applyInsets() {
        guard let view else { return }
        let insets = (top: view.topInset, bottom: view.bottomInset, horizontal: view.horizontalPadding)
        guard appliedInsets == nil || appliedInsets! != insets else { return }
        appliedInsets = insets
        viewport.applyInsets(top: insets.top, bottom: insets.bottom, horizontal: insets.horizontal)
    }

    // MARK: - Position

    /// Recolors and recenters for the view's position. Skips work while the
    /// current line and spoken cue are unchanged.
    private func followPosition(recentered: Bool) {
        guard let view else { return }
        let seconds = projectedPosition()
        let line = content.lineIndex(at: seconds)
        let cue = line.flatMap { content.spokenCue(inLine: $0, at: seconds) }
        let requested = view.anchor.requestedSeconds
        let moved = line != currentLine || cue != spokenCue || requested != requestedSeconds
        guard moved || recentered else { return }
        let previousLine = currentLine
        currentLine = line
        spokenCue = cue
        requestedSeconds = requested
        if moved {
            refreshColorState(invalidating: linesSpan(previousLine, line))
            viewport.refreshVisibleColors()
        }
        if view.isTracking {
            centerOnSpokenWord(forced: recentered, animated: !recentered)
        }
    }

    /// The span of lines between the two positions, for invalidating the
    /// colors the move changed.
    private func linesSpan(_ first: Int?, _ second: Int?) -> ClosedRange<Int> {
        let low = min(first ?? 0, second ?? 0)
        let high = max(first ?? 0, second ?? 0)
        return low...high
    }

    /// Pushes the current position and matches into the painter, dropping
    /// the cached lines the change invalidates. Must run before any repaint
    /// that should show a change.
    private func refreshColorState(invalidating lines: ClosedRange<Int>?) {
        let state = content.colorState(currentLine: currentLine, spokenCue: spokenCue, requestedSeconds: requestedSeconds, matches: searchModel.matches)
        viewport.painter.setState(state, invalidating: lines)
    }

    // MARK: - Content

    /// Rebuilds the text model from the view's lines and chapters and
    /// resets everything keyed to the old text. The caller recenters, which
    /// measures and places the new lines.
    private func rebuildContent() {
        guard let view else { return }
        content = TranscriptContent(sourceLines: view.lines, chapters: view.chapters)
        searchModel.reset()
        let seconds = projectedPosition()
        currentLine = content.lineIndex(at: seconds)
        spokenCue = currentLine.flatMap { content.spokenCue(inLine: $0, at: seconds) }
        requestedSeconds = view.anchor.requestedSeconds
        viewport.setContent(lines: renderLines(), ranges: content.lineRanges)
        refreshColorState(invalidating: nil)
    }

    /// The content's lines ready to render: each line's text without its
    /// trailing newline or paragraph style, under the spacing the styles
    /// define. The metrics own the spacing, so the engine never applies
    /// paragraph spacing on its own.
    private func renderLines() -> [TranscriptRenderLine] {
        let bodySpacing = TranscriptStyle.paragraph.paragraphSpacing
        let titleSpacing = TranscriptStyle.titleParagraph.paragraphSpacingBefore
        return content.lineRanges.enumerated().map { position, range in
            let text = NSMutableAttributedString(attributedString: content.attributedString.attributedSubstring(from: range))
            text.removeAttribute(.paragraphStyle, range: NSRange(location: 0, length: text.length))
            let isTitle = content.titleChapters[position] != nil
            return TranscriptRenderLine(
                text: text,
                spacingBefore: isTitle ? titleSpacing : 0,
                spacingAfter: bodySpacing
            )
        }
    }

    // MARK: - Search

    /// Installs a settled search: the colors refresh for the new matches,
    /// and a fresh query centers its landing match.
    private func installSearchOutcome(_ outcome: TranscriptSearchOutcome) {
        refreshColorState(invalidating: nil)
        viewport.refreshVisibleColors()
        if let match = outcome.landingMatch {
            center(onStorageRange: match, forced: true, animated: true)
            view?.onUserScroll()
        }
        publishMatchState()
    }

    /// Steps to the next or previous match, wrapping, and centers it.
    func stepMatch(by delta: Int) {
        guard let match = searchModel.stepMatch(by: delta) else { return }
        center(onStorageRange: match, forced: true, animated: true)
        view?.onUserScroll()
        publishMatchState()
    }

    /// Published outside the SwiftUI update this can run in.
    private func setSearching(_ searching: Bool) {
        Task { @MainActor in self.controller?.isSearching = searching }
    }

    /// Published outside the SwiftUI update this can run in.
    private func publishMatchState() {
        let index = searchModel.matchIndex
        let count = searchModel.matches.count
        Task { @MainActor in
            self.controller?.matchIndex = index
            self.controller?.matchCount = count
        }
    }

    // MARK: - Centering

    /// Scrolls the spoken word's visual line to the viewport's center. The
    /// unforced form skips targets on the already-centered visual line, so
    /// tracking steps once per line of text.
    func centerOnSpokenWord(forced: Bool, animated: Bool) {
        guard let range = content.spokenTargetRange(line: currentLine, cue: spokenCue?.index) else { return }
        center(onStorageRange: range, forced: forced, animated: animated)
    }

    /// Centers the range's visual line: a nearby target glides after its
    /// corridor is measured, a far one jumps. An animated landing verifies
    /// itself, since measuring during the glide can move the target.
    /// Animation is off while another view covers the transcript, since
    /// nobody can watch the glide.
    private func center(onStorageRange range: NSRange, forced: Bool, animated: Bool) {
        guard let (line, local) = lineTarget(forStorage: range) else { return }
        let glides = viewport.prepareCorridor(to: line)
        guard let y = viewport.yMid(line: line, localRange: local) else { return }
        let animates = animated && glides && view?.isVisible != false
        viewport.scroller.center(onY: y, forced: forced, animated: animates) { [weak self] in
            self?.settleCenter(line: line, localRange: local, expectedY: y)
        }
    }

    /// Re-centers without animation when the landing drifted off the
    /// target, which happens when measuring moved the content mid-glide.
    private func settleCenter(line: Int, localRange: NSRange, expectedY: CGFloat) {
        guard let y = viewport.yMid(line: line, localRange: localRange),
              abs(y - expectedY) > 1
        else { return }
        viewport.scroller.center(onY: y, forced: true, animated: false)
    }

    /// The line holding the storage range, with the range in the line's
    /// local offsets.
    private func lineTarget(forStorage range: NSRange) -> (line: Int, localRange: NSRange)? {
        let ranges = content.lineRanges
        let position = ranges.partitioningIndex { $0.location + $0.length >= range.location }
        guard position < ranges.count else { return nil }
        let lineRange = ranges[position]
        let location = min(max(0, range.location - lineRange.location), lineRange.length)
        let length = min(range.length, lineRange.length - location)
        return (position, NSRange(location: location, length: length))
    }

    // MARK: - Clicks

    private func handleTap(atUTF16Index index: Int) {
        guard let view, let target = content.tapTarget(atUTF16Index: index) else { return }
        switch target {
        case .chapter(let chapter):
            view.onChapterTap(chapter)
        case .word(let cue):
            view.onWordTap(cue)
        }
    }
}
