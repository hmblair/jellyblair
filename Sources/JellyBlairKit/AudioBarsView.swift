import QuartzCore
import SwiftUI
#if canImport(AppKit)
import AppKit
#else
import UIKit
#endif

/// Bars driven by the live band levels of the playing audio.
public struct AudioBarsView: View {
    let meter: AudioLevelMeter
    let isPlaying: Bool

    /// Increased inside a selected list row, in sync with the accent pill,
    /// so the bars whiten exactly when the system whitens the row's text.
    @Environment(\.backgroundProminence) private var backgroundProminence

    /// The bars stop with the scene, which on the phone includes a locked
    /// screen during background playback.
    @Environment(\.scenePhase) private var scenePhase

    /// On the Mac the bars gray with the window's focus, like the accent on
    /// any SwiftUI control.
    #if canImport(AppKit)
    @Environment(\.controlActiveState) private var controlActiveState
    private var isWindowActive: Bool { controlActiveState != .inactive }
    #else
    private var isWindowActive: Bool { true }
    #endif

    public init(meter: AudioLevelMeter, isPlaying: Bool) {
        self.meter = meter
        self.isPlaying = isPlaying
    }

    public var body: some View {
        AudioBarsHost(
            meter: meter,
            isPlaying: isPlaying,
            isSceneActive: scenePhase == .active,
            isProminent: backgroundProminence == .increased,
            isWindowActive: isWindowActive
        )
            .frame(width: AudioBarsLayerView.totalWidth, height: AudioBarsLayerView.barMaxHeight)
    }
}

/// Bridges the bars' layer-backed view into SwiftUI.
private struct AudioBarsHost {
    let meter: AudioLevelMeter
    let isPlaying: Bool
    let isSceneActive: Bool
    let isProminent: Bool
    let isWindowActive: Bool
}

#if canImport(AppKit)
extension AudioBarsHost: NSViewRepresentable {
    func makeNSView(context: Context) -> AudioBarsLayerView {
        AudioBarsLayerView()
    }

    func updateNSView(_ view: AudioBarsLayerView, context: Context) {
        view.configure(meter: meter, isPlaying: isPlaying, isSceneActive: isSceneActive, isProminent: isProminent, isWindowActive: isWindowActive)
    }
}
#else
extension AudioBarsHost: UIViewRepresentable {
    func makeUIView(context: Context) -> AudioBarsLayerView {
        AudioBarsLayerView()
    }

    func updateUIView(_ view: AudioBarsLayerView, context: Context) {
        view.configure(meter: meter, isPlaying: isPlaying, isSceneActive: isSceneActive, isProminent: isProminent, isWindowActive: isWindowActive)
    }
}
#endif

/// The layer-backed view behind AudioBarsView.
final class AudioBarsLayerView: PlatformNativeView {
    static let barMaxHeight: CGFloat = 11
    private static let barMinHeight: CGFloat = 2
    private static let barWidth: CGFloat = 2
    private static let barSpacing: CGFloat = 1.5

    static var totalWidth: CGFloat {
        CGFloat(AudioLevelMeter.bandCount) * barWidth + CGFloat(AudioLevelMeter.bandCount - 1) * barSpacing
    }

    private var barLayers: [CALayer] = []
    private var meter: AudioLevelMeter?
    private var isPlaying = false
    private var isProminent = false
    private var isWindowActive = true
    private var barsDisplayLink: CADisplayLink?

    private var isSceneActive = true

    override init(frame: CGRect) {
        super.init(frame: frame)
        setUpLayers()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setUpLayers()
    }

    /// The backing layer, optional on both platforms so the setup code reads
    /// the same. AppKit creates it lazily; UIKit always has one.
    private var backingLayer: CALayer? { layer }

    private func setUpLayers() {
        #if canImport(AppKit)
        wantsLayer = true
        #endif
        for _ in 0..<AudioLevelMeter.bandCount {
            let bar = CALayer()
            bar.cornerRadius = Self.barWidth / 2
            backingLayer?.addSublayer(bar)
            barLayers.append(bar)
        }
        applyColors()
        #if canImport(UIKit)
        registerForTraitChanges(UITraitCollection.systemTraitsAffectingColorAppearance) { (view: AudioBarsLayerView, _: UITraitCollection) in
            view.applyColors()
        }
        #endif
    }

    #if canImport(AppKit)
    // Bar frames compute in top-left coordinates on both platforms.
    override var isFlipped: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        syncDisplayLink()
    }

    override func layout() {
        super.layout()
        renderBands()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyColors()
    }
    #else
    override func didMoveToWindow() {
        super.didMoveToWindow()
        syncDisplayLink()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        renderBands()
    }

    override func tintColorDidChange() {
        super.tintColorDidChange()
        applyColors()
    }
    #endif

    func configure(meter: AudioLevelMeter, isPlaying: Bool, isSceneActive: Bool, isProminent: Bool, isWindowActive: Bool) {
        self.meter = meter
        self.isPlaying = isPlaying
        self.isSceneActive = isSceneActive
        if isProminent != self.isProminent || isWindowActive != self.isWindowActive {
            self.isProminent = isProminent
            self.isWindowActive = isWindowActive
            applyColors()
        }
        syncDisplayLink()
        renderBands()
    }

    /// Runs the display link exactly while playing bars are on screen. The
    /// link's reads are what drive the meter's transform, so a stopped
    /// link stops that work too. The link retains the view until it is
    /// invalidated, which leaving the window always does.
    private func syncDisplayLink() {
        let shouldRun = isPlaying && isSceneActive && window != nil
        if shouldRun, barsDisplayLink == nil {
            let link = makeDisplayLink()
            // The common mode keeps the bars moving while a list scrolls.
            link.add(to: .main, forMode: .common)
            barsDisplayLink = link
        } else if !shouldRun, let barsDisplayLink {
            barsDisplayLink.invalidate()
            self.barsDisplayLink = nil
        }
    }

    /// A display link that ticks at the refresh rate of the view's screen.
    private func makeDisplayLink() -> CADisplayLink {
        #if canImport(AppKit)
        displayLink(target: self, selector: #selector(displayLinkDidFire))
        #else
        CADisplayLink(target: self, selector: #selector(displayLinkDidFire))
        #endif
    }

    @objc private func displayLinkDidFire(_ link: CADisplayLink) {
        renderBands()
    }

    /// Sets the bar frames from the current band levels, or from rest while
    /// paused. Reading the meter while paused would race the last audio
    /// buffers, which can land after the meter is reset and leave the bars
    /// frozen at their final levels with no redraw left to clear them.
    private func renderBands() {
        guard let meter else { return }
        let bands = isPlaying
            ? meter.currentBands()
            : [Float](repeating: 0, count: AudioLevelMeter.bandCount)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (index, bar) in barLayers.enumerated() {
            let height = Self.barMinHeight + CGFloat(bands[index]) * (Self.barMaxHeight - Self.barMinHeight)
            let x = CGFloat(index) * (Self.barWidth + Self.barSpacing)
            bar.frame = CGRect(x: x, y: bounds.height - height, width: Self.barWidth, height: height)
        }
        CATransaction.commit()
    }

    /// Applies the bar color without the layers' implicit fade, so the bars
    /// snap with the system's controls when the window or appearance changes.
    private func applyColors() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        #if canImport(AppKit)
        effectiveAppearance.performAsCurrentDrawingAppearance {
            let color = isProminent ? NSColor.white : NSColor.accent(windowActive: isWindowActive)
            for bar in barLayers {
                bar.backgroundColor = color.cgColor
            }
        }
        #else
        let color: UIColor = isProminent ? .white : tintColor
        for bar in barLayers {
            bar.backgroundColor = color.cgColor
        }
        #endif
        CATransaction.commit()
    }
}
