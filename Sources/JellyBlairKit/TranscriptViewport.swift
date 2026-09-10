import Foundation
#if canImport(AppKit)
import AppKit
#else
import UIKit
#endif

/// One transcript line on screen: a small view that draws its colored text
/// through the shared renderer.
final class TranscriptLineView: PlatformNativeView {
    private(set) var text: NSAttributedString?
    private weak var renderer: TranscriptLineRenderer?

    #if canImport(AppKit)
    override var isFlipped: Bool { true }
    #endif

    override init(frame: CGRect) {
        super.init(frame: frame)
        #if canImport(UIKit)
        isOpaque = false
        backgroundColor = .clear
        contentMode = .redraw
        #endif
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    func configure(text: NSAttributedString, renderer: TranscriptLineRenderer) {
        self.renderer = renderer
        guard text !== self.text else { return }
        self.text = text
        setNeedsDisplay(bounds)
    }

    override func draw(_ dirtyRect: CGRect) {
        guard let text, let renderer else { return }
        renderer.draw(text, width: bounds.width, at: .zero)
    }
}

#if canImport(AppKit)
/// The transcript's document view, a bare canvas holding the line views.
final class TranscriptCanvasView: NSView {
    override var isFlipped: Bool { true }
}
#else
/// A scroll view that reports its own layouts, so the viewport sees the
/// first real width and every width change without depending on a SwiftUI
/// update.
final class TranscriptScrollView: UIScrollView {
    var onLayout: (() -> Void)?

    override func layoutSubviews() {
        super.layoutSubviews()
        onLayout?()
    }
}

/// A gesture target that holds its owner weakly. UIKit's recognizers
/// retain their targets, so a viewport as the target would keep itself
/// and its scroll view alive in a cycle.
@MainActor
private final class WeakTapTarget: NSObject {
    weak var owner: TranscriptViewport?

    @objc func handleTap(_ recognizer: UITapGestureRecognizer) {
        owner?.handleTap(recognizer)
    }
}
#endif

/// Owns the transcript's scroll container and the pool of line views, and
/// keeps the pool covering the visible lines. All geometry changes funnel
/// through one coalesced update pass per main-loop turn, so nothing here
/// re-enters the platform's own layout mid-flight.
@MainActor
final class TranscriptViewport: NSObject {
    /// Points measured beyond the visible edges, so a scroll finds its
    /// rows already placed.
    private static let overscan: CGFloat = 300

    /// The longest corridor a centering glides across. A farther target
    /// jumps without animation, since measuring the whole span first would
    /// stall and the glide would be a blur anyway.
    private static let corridorLimit = 300

    private let renderer: TranscriptLineRenderer
    let metrics: TranscriptLineMetrics
    let painter: TranscriptLinePainter
    let scroller: TranscriptScroller

    /// Called when the user scrolls the transcript themselves.
    var onUserScroll: (() -> Void)?
    /// Called with the tapped character's UTF-16 storage index.
    var onTap: ((Int) -> Void)?
    /// Called after a width change has re-laid the visible lines.
    var onWidthChange: (() -> Void)?

    private var baseLines: [TranscriptRenderLine] = []
    private var lineRanges: [NSRange] = []
    private var horizontalPadding: CGFloat = 0
    private var lastWidth: CGFloat = 0

    private var pool: [Int: TranscriptLineView] = [:]
    private var spare: [TranscriptLineView] = []
    private var updateScheduled = false

    #if canImport(AppKit)
    let scrollView: MomentumCancellingScrollView
    private let canvas = TranscriptCanvasView()
    private var scrollObserver: NSObjectProtocol?
    private var boundsObserver: NSObjectProtocol?
    #else
    let scrollView = TranscriptScrollView()
    private let tapTarget = WeakTapTarget()
    #endif

    override init() {
        renderer = TranscriptLineRenderer()
        metrics = TranscriptLineMetrics(renderer: renderer)
        painter = TranscriptLinePainter()
        #if canImport(AppKit)
        scrollView = MomentumCancellingScrollView()
        scroller = TranscriptScroller(scrollView: scrollView)
        #else
        scroller = TranscriptScroller(scrollView: scrollView)
        #endif
        super.init()
        scroller.documentHeight = { [weak self] in self?.metrics.documentHeight() ?? 0 }
        configureScrollView()
    }

    deinit {
        #if canImport(AppKit)
        MainActor.assumeIsolated {
            for observer in [scrollObserver, boundsObserver] {
                if let observer {
                    NotificationCenter.default.removeObserver(observer)
                }
            }
        }
        #endif
    }

    // MARK: - Setup

    private func configureScrollView() {
        #if canImport(AppKit)
        scrollView.documentView = canvas
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.automaticallyAdjustsContentInsets = false
        let click = NSClickGestureRecognizer(target: self, action: #selector(handleClick(_:)))
        canvas.addGestureRecognizer(click)
        scrollObserver = NotificationCenter.default.addObserver(
            forName: NSScrollView.willStartLiveScrollNotification,
            object: scrollView,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.scroller.cancelGlide()
                self?.onUserScroll?()
            }
        }
        scrollView.contentView.postsBoundsChangedNotifications = true
        boundsObserver = NotificationCenter.default.addObserver(
            forName: NSView.boundsDidChangeNotification,
            object: scrollView.contentView,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.setNeedsUpdate()
            }
        }
        #else
        scrollView.backgroundColor = .clear
        scrollView.contentInsetAdjustmentBehavior = .never
        scrollView.alwaysBounceVertical = true
        scrollView.delegate = self
        tapTarget.owner = self
        let tap = UITapGestureRecognizer(target: tapTarget, action: #selector(WeakTapTarget.handleTap(_:)))
        scrollView.addGestureRecognizer(tap)
        scrollView.onLayout = { [weak self] in
            self?.setNeedsUpdate()
        }
        #endif
    }

    // MARK: - Content

    /// Installs new lines. Every measurement and pooled view is void; the
    /// caller recenters afterwards.
    func setContent(lines: [TranscriptRenderLine], ranges: [NSRange]) {
        baseLines = lines
        lineRanges = ranges
        metrics.setLines(lines)
        painter.setContent(lines: lines, ranges: ranges)
        scroller.resetCentering()
        clearPool()
        setNeedsUpdate()
    }

    /// Applies the pane's insets. A horizontal padding change resizes the
    /// text like a width change.
    func applyInsets(top: CGFloat, bottom: CGFloat, horizontal: CGFloat) {
        #if canImport(AppKit)
        scrollView.contentInsets = NSEdgeInsets(top: top, left: 0, bottom: bottom, right: 0)
        #else
        scrollView.contentInset = UIEdgeInsets(top: top, left: 0, bottom: bottom, right: 0)
        #endif
        guard horizontal != horizontalPadding else { return }
        horizontalPadding = horizontal
        lastWidth = 0
        setNeedsUpdate()
    }

    /// Refreshes the colored text of the pooled views, after a color
    /// change. Painting is cheap, so every visible line refreshes; the
    /// cache keeps unchanged lines identical and their views untouched.
    func refreshVisibleColors() {
        for (line, view) in pool {
            view.configure(text: painter.coloredLine(line), renderer: renderer)
        }
    }

    // MARK: - Update pass

    /// Schedules one update for the next main-loop turn. Scrolls, resizes,
    /// and content changes all coalesce here.
    func setNeedsUpdate() {
        guard !updateScheduled else { return }
        updateScheduled = true
        Task { @MainActor in
            self.updateScheduled = false
            self.updatePass()
        }
    }

    private func updatePass() {
        let width = viewportWidth()
        guard width > 0 else { return }
        if width != lastWidth {
            adoptWidth(width)
        }
        reconcileVisible()
    }

    /// Adopts a new viewport width, keeping the line at the top of the
    /// screen where it was.
    private func adoptWidth(_ width: CGFloat) {
        let anchor = topAnchor()
        lastWidth = width
        metrics.setWidth(max(0, width - 2 * horizontalPadding))
        scroller.resetCentering()
        #if canImport(AppKit)
        canvas.setFrameSize(CGSize(width: width, height: canvas.frame.height))
        #endif
        if let anchor {
            metrics.relocateWindow(around: anchor.line)
            updateContentHeight()
            setScrollY(metrics.top(of: anchor.line) - anchor.offsetFromViewportTop)
        }
        onWidthChange?()
    }

    /// The line at the viewport's top and its screen offset, the pair that
    /// survives a re-layout.
    private func topAnchor() -> (line: Int, offsetFromViewportTop: CGFloat)? {
        guard metrics.lineCount > 0, lastWidth > 0 else { return nil }
        let viewportTop = visibleDocRect().minY
        let line = metrics.lineIndex(atY: viewportTop)
        return (line, metrics.top(of: line) - viewportTop)
    }

    /// Brings the pool in line with the viewport: measures the visible
    /// band, absorbs the shift that measuring caused, and places one view
    /// per visible line.
    private func reconcileVisible() {
        guard metrics.lineCount > 0, metrics.width > 0 else {
            clearPool()
            updateContentHeight()
            return
        }
        var viewport = visibleDocRect().insetBy(dx: 0, dy: -Self.overscan)
        let estimated = metrics.lineIndex(atY: viewport.minY)...metrics.lineIndex(atY: viewport.maxY)
        absorb(metrics.ensureMeasured(covering: estimated))
        viewport = visibleDocRect().insetBy(dx: 0, dy: -Self.overscan)
        let first = metrics.lineIndex(atY: viewport.minY)
        let last = metrics.lineIndex(atY: viewport.maxY)
        // A shift can expose a line or two past the measured band; this
        // pass is adjacent to the window, so it extends without relocating.
        absorb(metrics.ensureMeasured(covering: first...last))
        for (line, view) in pool where line < first || line > last {
            view.removeFromSuperview()
            spare.append(view)
            pool.removeValue(forKey: line)
        }
        for line in first...last {
            place(line)
        }
        updateContentHeight()
    }

    private func place(_ line: Int) {
        guard metrics.isMeasured(line) else { return }
        let view = pool[line] ?? dequeueView(for: line)
        let frame = CGRect(
            x: horizontalPadding,
            y: metrics.textTop(of: line),
            width: metrics.width,
            height: metrics.textHeight(of: line)
        )
        if view.frame != frame {
            view.frame = frame
            view.setNeedsDisplay(view.bounds)
        }
        view.configure(text: painter.coloredLine(line), renderer: renderer)
    }

    private func dequeueView(for line: Int) -> TranscriptLineView {
        let view = spare.popLast() ?? TranscriptLineView(frame: .zero)
        pool[line] = view
        #if canImport(AppKit)
        canvas.addSubview(view)
        #else
        scrollView.addSubview(view)
        #endif
        return view
    }

    private func clearPool() {
        for view in pool.values {
            view.removeFromSuperview()
            spare.append(view)
        }
        pool.removeAll()
    }

    private func updateContentHeight() {
        let height = metrics.documentHeight()
        #if canImport(AppKit)
        if canvas.frame.size != CGSize(width: viewportWidth(), height: height) {
            canvas.setFrameSize(CGSize(width: viewportWidth(), height: height))
        }
        #else
        let size = CGSize(width: viewportWidth(), height: height)
        if scrollView.contentSize != size {
            scrollView.contentSize = size
        }
        #endif
    }

    // MARK: - Centering support

    /// The document y of the visual line holding the local range within
    /// the line, measuring the line's neighborhood first when needed.
    func yMid(line: Int, localRange: NSRange) -> CGFloat? {
        guard metrics.width > 0, baseLines.indices.contains(line) else { return nil }
        if !metrics.isMeasured(line) {
            absorb(metrics.ensureMeasured(covering: line - 20...line + 20))
        }
        guard let rect = renderer.rect(forCharacterRange: localRange, in: baseLines[line].text, width: metrics.width) else { return nil }
        return metrics.textTop(of: line) + rect.midY
    }

    /// Measures the span between the viewport and the target when it is
    /// short enough to glide across. Returns false for a far target, which
    /// should jump instead.
    func prepareCorridor(to line: Int) -> Bool {
        guard metrics.lineCount > 0 else { return false }
        let viewport = visibleDocRect()
        let first = metrics.lineIndex(atY: viewport.minY)
        let last = metrics.lineIndex(atY: viewport.maxY)
        let corridor = min(first, line)...max(last, line)
        guard corridor.count <= Self.corridorLimit else { return false }
        absorb(metrics.ensureMeasured(covering: corridor))
        return true
    }

    /// Applies a coverage result to the screen. The content height syncs
    /// first: the platform clamps scrolls against the view's size, so a
    /// scroll issued against a stale size would collapse to the top.
    private func absorb(_ coverage: TranscriptCoverage) {
        updateContentHeight()
        switch coverage {
        case .extended(let shift):
            if abs(shift) > 0.5 {
                shiftScroll(by: shift)
            }
        case .relocated:
            scroller.resetCentering()
        }
    }

    // MARK: - Scrolling

    func visibleDocRect() -> CGRect {
        #if canImport(AppKit)
        scrollView.contentView.bounds
        #else
        CGRect(origin: scrollView.contentOffset, size: scrollView.bounds.size)
        #endif
    }

    private func viewportWidth() -> CGFloat {
        #if canImport(AppKit)
        scrollView.contentView.bounds.width
        #else
        scrollView.bounds.width
        #endif
    }

    /// Moves the scroll with content that shifted in document coordinates,
    /// so the screen shows no motion.
    private func shiftScroll(by delta: CGFloat) {
        #if canImport(AppKit)
        let clip = scrollView.contentView
        clip.setBoundsOrigin(CGPoint(x: clip.bounds.origin.x, y: clip.bounds.origin.y + delta))
        scrollView.reflectScrolledClipView(clip)
        #else
        scrollView.contentOffset.y += delta
        #endif
        scroller.shift(by: delta)
    }

    private func setScrollY(_ y: CGFloat) {
        #if canImport(AppKit)
        let clip = scrollView.contentView
        clip.setBoundsOrigin(CGPoint(x: clip.bounds.origin.x, y: y))
        scrollView.reflectScrolledClipView(clip)
        #else
        scrollView.contentOffset.y = y
        #endif
    }

    // MARK: - Taps

    #if canImport(AppKit)
    @objc private func handleClick(_ recognizer: NSClickGestureRecognizer) {
        handleTap(atDocumentPoint: recognizer.location(in: canvas))
    }
    #else
    fileprivate func handleTap(_ recognizer: UITapGestureRecognizer) {
        handleTap(atDocumentPoint: recognizer.location(in: scrollView))
    }
    #endif

    private func handleTap(atDocumentPoint point: CGPoint) {
        guard metrics.lineCount > 0, metrics.width > 0 else { return }
        let line = metrics.lineIndex(atY: point.y)
        guard metrics.isMeasured(line) else { return }
        let local = CGPoint(x: point.x - horizontalPadding, y: point.y - metrics.textTop(of: line))
        guard let index = renderer.characterIndex(at: local, in: baseLines[line].text, width: metrics.width) else { return }
        onTap?(lineRanges[line].location + index)
    }
}

#if canImport(UIKit)
extension TranscriptViewport: UIScrollViewDelegate {
    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        setNeedsUpdate()
    }

    func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
        scroller.cancelGlide()
        onUserScroll?()
    }
}
#endif
