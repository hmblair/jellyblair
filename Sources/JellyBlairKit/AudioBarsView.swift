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

    public init(meter: AudioLevelMeter, isPlaying: Bool) {
        self.meter = meter
        self.isPlaying = isPlaying
    }

    public var body: some View {
        AudioBarsHost(meter: meter, isPlaying: isPlaying, isProminent: backgroundProminence == .increased)
            .frame(width: AudioBarsLayerView.totalWidth, height: AudioBarsLayerView.barMaxHeight)
    }
}

/// Bridges the bars' layer-backed view into SwiftUI.
private struct AudioBarsHost {
    let meter: AudioLevelMeter
    let isPlaying: Bool
    let isProminent: Bool
}

#if canImport(AppKit)
extension AudioBarsHost: NSViewRepresentable {
    func makeNSView(context: Context) -> AudioBarsLayerView {
        AudioBarsLayerView()
    }

    func updateNSView(_ view: AudioBarsLayerView, context: Context) {
        view.configure(meter: meter, isPlaying: isPlaying, isProminent: isProminent)
    }
}
#else
extension AudioBarsHost: UIViewRepresentable {
    func makeUIView(context: Context) -> AudioBarsLayerView {
        AudioBarsLayerView()
    }

    func updateUIView(_ view: AudioBarsLayerView, context: Context) {
        view.configure(meter: meter, isPlaying: isPlaying, isProminent: isProminent)
    }
}
#endif

/// The layer-backed view behind AudioBarsView.
final class AudioBarsLayerView: PlatformNativeView {
    static let barMaxHeight: CGFloat = 11
    private static let barMinHeight: CGFloat = 2
    private static let barWidth: CGFloat = 2
    private static let barSpacing: CGFloat = 1.5
    private static let tickInterval: TimeInterval = 1.0 / 30.0

    static var totalWidth: CGFloat {
        CGFloat(AudioLevelMeter.bandCount) * barWidth + CGFloat(AudioLevelMeter.bandCount - 1) * barSpacing
    }

    private var barLayers: [CALayer] = []
    private var meter: AudioLevelMeter?
    private var isPlaying = false
    private var isProminent = false
    private var timer: Timer?

    override init(frame: CGRect) {
        super.init(frame: frame)
        setUpLayers()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setUpLayers()
    }

    deinit {
        timer?.invalidate()
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
    }

    #if canImport(AppKit)
    // Bar frames compute in top-left coordinates on both platforms.
    override var isFlipped: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        syncTimer()
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
        syncTimer()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        renderBands()
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        applyColors()
    }

    override func tintColorDidChange() {
        super.tintColorDidChange()
        applyColors()
    }
    #endif

    func configure(meter: AudioLevelMeter, isPlaying: Bool, isProminent: Bool) {
        self.meter = meter
        self.isPlaying = isPlaying
        if isProminent != self.isProminent {
            self.isProminent = isProminent
            applyColors()
        }
        syncTimer()
        renderBands()
    }

    /// Runs the tick timer exactly while playing on screen.
    private func syncTimer() {
        let shouldRun = isPlaying && window != nil
        if shouldRun, timer == nil {
            let timer = Timer(timeInterval: Self.tickInterval, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.renderBands() }
            }
            // The common mode keeps the bars moving while a list scrolls.
            RunLoop.main.add(timer, forMode: .common)
            self.timer = timer
        } else if !shouldRun, let timer {
            timer.invalidate()
            self.timer = nil
        }
    }

    /// Sets the bar frames from the current band levels.
    private func renderBands() {
        guard let meter else { return }
        let bands = meter.currentBands()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (index, bar) in barLayers.enumerated() {
            let height = Self.barMinHeight + CGFloat(bands[index]) * (Self.barMaxHeight - Self.barMinHeight)
            let x = CGFloat(index) * (Self.barWidth + Self.barSpacing)
            bar.frame = CGRect(x: x, y: bounds.height - height, width: Self.barWidth, height: height)
        }
        CATransaction.commit()
    }

    private func applyColors() {
        #if canImport(AppKit)
        effectiveAppearance.performAsCurrentDrawingAppearance {
            let color = isProminent ? NSColor.white : NSColor.controlAccentColor
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
    }
}
