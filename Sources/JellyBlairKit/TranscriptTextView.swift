// The transcript never measures estimated text. Whenever the view has a
// real width, the whole document is laid out in one eager pass — well
// under a second even for a large book — and nothing centers before that
// pass has run. This one rule keeps the rest simple:
//
// - Positions read from the layout are exact, so centering is: measure
//   the target's frame, scroll to it.
//
// - Colors. Rendering attributes always hold TranscriptColorResolver's
//   current output: every color change repaints its whole range at once
//   through TranscriptColorEngine, which nudges the on-screen part to
//   redraw. Off-screen text draws its updated attributes when a scroll
//   reaches it.
//
// - A width change re-lays the whole document. The reader's place is kept
//   by keepingViewport on the Mac and by the text view itself on iOS, and
//   tracking recenters afterwards. The view reports its own sizing, so
//   the first layout never depends on a SwiftUI update arriving.
//
// The concerns split into components with one owner each:
// TranscriptContent (the pure text model), TranscriptColorEngine (colors),
// TranscriptSearchModel (matches), TranscriptScroller (centering and scroll
// compensation), and TranscriptTextGeometry (layout queries and forcing).
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

/// The transcript as one native text view. The whole book is laid out in
/// one eager pass, so the text system answers where any character range
/// sits exactly, and following the narration needs no view-level
/// machinery. Word colors are rendering attributes, painted by a resolver;
/// recoloring changes no metrics and never moves the content.
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

/// Orchestrates the transcript components around the platform text view:
/// tracks the playback position, pushes state into the color engine, and
/// routes view events to the search model and the scroller.
@MainActor
public final class TranscriptTextCoordinator: NSObject {
    fileprivate weak var controller: TranscriptController?

    private var view: TranscriptTextView?
    /// The text model on display.
    private var content = TranscriptContent(sourceLines: [], chapters: [])
    private var currentLine: Int?
    private var spokenCueIndex: Int?
    /// The anchor's requested position, which the colors depend on.
    private var requestedSeconds: Double = 0

    private let searchModel = TranscriptSearchModel()
    private var geometry: TranscriptTextGeometry!
    private var colorEngine: TranscriptColorEngine!
    private var scroller: TranscriptScroller!

    /// The width the document was last fully laid out at: zero until the
    /// first eager pass, and nothing centers before that pass has run.
    private var laidOutWidth: CGFloat = 0
    /// Wakes the coordinator at the next line or cue boundary.
    private var tickTimer: Timer?

    #if canImport(AppKit)
    private var scrollView: MomentumCancellingScrollView!
    private var textView: NSTextView!
    private var scrollObserver: NSObjectProtocol?
    private var frameObserver: NSObjectProtocol?
    private var liveResizeObserver: NSObjectProtocol?
    #else
    private var textView: UITextView!
    #endif

    override init() {
        super.init()
        wireSearchModel()
    }

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

        makeComponents()
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
        // The view reports its own sizing, so the first layout does not
        // depend on a SwiftUI update arriving after the view gets a width.
        textView.postsFrameChangedNotifications = true
        frameObserver = NotificationCenter.default.addObserver(
            forName: NSView.frameDidChangeNotification,
            object: textView,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.handleViewLayout()
            }
        }
        // A live resize changes the width every frame; the full pass waits
        // for the resize to end.
        liveResizeObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didEndLiveResizeNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            MainActor.assumeIsolated {
                guard let self, (notification.object as? NSWindow) === self.textView.window else { return }
                self.handleViewLayout()
            }
        }
        return scrollView
    }
    #else
    func makeTextView() -> UITextView {
        let textView = SizeReportingTextView(usingTextLayoutManager: true)
        textView.isEditable = false
        textView.isSelectable = false
        textView.backgroundColor = .clear
        // The centering math reads contentInset back, so the system must not adjust it.
        textView.contentInsetAdjustmentBehavior = .never
        textView.delegate = self
        self.textView = textView

        makeComponents()
        let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
        textView.addGestureRecognizer(tap)
        // The view reports its own sizing, so the first layout does not
        // depend on a SwiftUI update arriving after the view gets a width.
        textView.onLayout = { [weak self] in
            self?.handleViewLayout()
        }
        return textView
    }
    #endif

    /// Builds the components around the created views.
    private func makeComponents() {
        #if canImport(AppKit)
        geometry = TranscriptTextGeometry(textView: textView, scrollView: scrollView)
        scroller = TranscriptScroller(scrollView: scrollView, geometry: geometry)
        #else
        geometry = TranscriptTextGeometry(textView: textView)
        scroller = TranscriptScroller(textView: textView, geometry: geometry)
        #endif
        colorEngine = TranscriptColorEngine(textView: textView, geometry: geometry)
        colorEngine.installValidator()
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
            #if canImport(AppKit)
            for observer in [scrollObserver, frameObserver, liveResizeObserver] {
                if let observer {
                    NotificationCenter.default.removeObserver(observer)
                }
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
        let laidOut = layOutDocumentIfNeeded()
        if contentChanged || view.searchQuery != searchModel.appliedQuery || view.searchIsCaseSensitive != searchModel.appliedCaseSensitive {
            searchModel.apply(query: view.searchQuery, caseSensitive: view.searchIsCaseSensitive, text: content.plainText)
        }
        followPosition(recentered: contentChanged || laidOut)
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

    // MARK: - Position

    /// Recolors and recenters for the view's position. Skips work while the
    /// current line and spoken cue are unchanged.
    private func followPosition(recentered: Bool) {
        guard let view else { return }
        let seconds = projectedPosition()
        let line = content.lineIndex(at: seconds)
        let cue = line.flatMap { content.spokenCueIndex(inLine: $0, at: seconds) }
        let requested = view.anchor.requestedSeconds
        let moved = line != currentLine || cue != spokenCueIndex || requested != requestedSeconds
        guard moved || recentered else { return }
        let previousLine = currentLine
        currentLine = line
        spokenCueIndex = cue
        requestedSeconds = requested
        refreshColorState()
        if moved {
            recolor(fromLine: previousLine, toLine: line)
        }
        if view.isTracking {
            centerOnSpokenWord(forced: recentered, animated: !recentered)
        }
    }

    /// Recolors the span of lines between the stored position and the given
    /// one.
    private func recolor(fromLine previousLine: Int?, toLine line: Int?) {
        let oldLine = previousLine ?? 0
        let newLine = line ?? 0
        colorEngine.repaintColors(in: content.linesRange(from: min(oldLine, newLine), to: max(oldLine, newLine)))
    }

    /// Pushes the current position and matches into the color engine, so
    /// the next repaint reflects them. Must run before any repaint that
    /// should show a change.
    private func refreshColorState() {
        colorEngine.state = content.colorState(currentLine: currentLine, spokenCue: spokenCueIndex, requestedSeconds: requestedSeconds, matches: searchModel.matches)
    }

    // MARK: - Content

    /// Rebuilds the text model from the view's lines and chapters, installs
    /// it in the storage, and resets everything keyed to the old text. The
    /// eager layout pass follows through layOutDocumentIfNeeded.
    private func rebuildContent() {
        guard let view else { return }
        content = TranscriptContent(sourceLines: view.lines, chapters: view.chapters)
        searchModel.reset()
        scroller.resetCentering()
        laidOutWidth = 0
        let seconds = projectedPosition()
        currentLine = content.lineIndex(at: seconds)
        spokenCueIndex = currentLine.flatMap { content.spokenCueIndex(inLine: $0, at: seconds) }
        requestedSeconds = view.anchor.requestedSeconds
        refreshColorState()
        geometry.storage?.setAttributedString(content.attributedString)
    }

    // MARK: - Eager layout

    /// Lays the whole document out at the view's width and repaints its
    /// colors, so every position and color the transcript works with
    /// afterwards is exact. Runs once per content or width, and only when
    /// the view has a real width: until then nothing centers, and the view
    /// reports its first sizing through handleViewLayout. A live window
    /// resize changes the width every frame, so the pass waits for the end
    /// notification. Returns true when it ran, so the caller recenters.
    private func layOutDocumentIfNeeded() -> Bool {
        #if canImport(AppKit)
        if textView.inLiveResize { return false }
        #endif
        let width = textView.bounds.width
        guard width > 0, width != laidOutWidth, let storage = geometry.storage else { return false }
        laidOutWidth = width
        scroller.keepingViewport {
            geometry.ensureLayout(forStorage: NSRange(location: 0, length: storage.length))
            geometry.updateContentGeometry()
        }
        colorEngine.repaintAllColors()
        return true
    }

    /// Runs on every layout of the view itself: the first real width and
    /// every width change re-lay the document and recenter.
    private func handleViewLayout() {
        if layOutDocumentIfNeeded() {
            followPosition(recentered: true)
        }
    }

    // MARK: - Search

    /// Installs a settled search: the colors refresh for the new matches,
    /// and a fresh query centers its landing match.
    private func installSearchOutcome(_ outcome: TranscriptSearchOutcome) {
        refreshColorState()
        if outcome.needsRepaint {
            colorEngine.repaintAllColors()
        }
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
        guard let range = content.spokenTargetRange(line: currentLine, cue: spokenCueIndex) else { return }
        center(onStorageRange: range, forced: forced, animated: animated)
    }

    /// Centers through the scroller, once the document is laid out: before
    /// the eager pass no measured position is real. Animation is off while
    /// another view covers the transcript, since nobody can watch the
    /// glide.
    private func center(onStorageRange range: NSRange, forced: Bool, animated: Bool) {
        guard laidOutWidth > 0 else { return }
        scroller.center(onStorageRange: range, forced: forced, animated: animated && view?.isVisible != false)
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

#if !canImport(AppKit)
extension TranscriptTextCoordinator: UITextViewDelegate {
    public func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
        view?.onUserScroll()
    }
}

/// A text view that reports each of its own layouts, so the coordinator
/// sees the first real width and every width change without depending on
/// a SwiftUI update.
final class SizeReportingTextView: UITextView {
    var onLayout: (() -> Void)?

    override func layoutSubviews() {
        super.layoutSubviews()
        onLayout?()
    }
}
#endif
