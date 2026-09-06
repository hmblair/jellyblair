import QuartzCore
import SwiftUI
#if canImport(AppKit)
import AppKit
#else
import UIKit
#endif

/// The state a progress bar animates from: the filled fraction at a wall-clock
/// moment, and the rate the fraction grows.
struct ProgressAnchor: Equatable {
    var fraction: Double
    var fractionsPerSecond: Double
    var date: Date
}

/// A track-and-fill progress bar whose motion is a single linear Core
/// Animation animation to the end of the range. The render server moves the
/// bar; the app only touches it when the anchor changes.
struct AnimatedProgressBar {
    var anchor: ProgressAnchor
}

#if canImport(AppKit)
extension AnimatedProgressBar: NSViewRepresentable {
    func makeNSView(context: Context) -> ProgressBarLayerView {
        ProgressBarLayerView()
    }

    func updateNSView(_ view: ProgressBarLayerView, context: Context) {
        view.setAnchor(anchor)
    }
}
#else
extension AnimatedProgressBar: UIViewRepresentable {
    func makeUIView(context: Context) -> ProgressBarLayerView {
        ProgressBarLayerView()
    }

    func updateUIView(_ view: ProgressBarLayerView, context: Context) {
        view.setAnchor(anchor)
    }
}
#endif

/// The layer-backed platform view behind AnimatedProgressBar.
final class ProgressBarLayerView: PlatformNativeView {
    private static let barHeight: CGFloat = 9
    private static let animationKey = "progress"

    private let trackLayer = CALayer()
    private let fillLayer = CALayer()
    private var anchor = ProgressAnchor(fraction: 0, fractionsPerSecond: 0, date: .distantPast)

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
        trackLayer.cornerRadius = Self.barHeight / 2
        fillLayer.cornerRadius = Self.barHeight / 2
        fillLayer.anchorPoint = CGPoint(x: 0, y: 0.5)
        backingLayer?.addSublayer(trackLayer)
        backingLayer?.addSublayer(fillLayer)
        applyColors()
    }

    #if canImport(AppKit)
    // NSView exposes its backing layer as optional; UIView's is not.
    override func layout() {
        super.layout()
        layoutLayers()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyColors()
    }
    #else
    override func layoutSubviews() {
        super.layoutSubviews()
        layoutLayers()
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

    private func applyColors() {
        #if canImport(AppKit)
        effectiveAppearance.performAsCurrentDrawingAppearance {
            trackLayer.backgroundColor = NSColor.labelColor.withAlphaComponent(0.15).cgColor
            fillLayer.backgroundColor = NSColor.controlAccentColor.cgColor
        }
        #else
        trackLayer.backgroundColor = UIColor.label.withAlphaComponent(0.15).cgColor
        fillLayer.backgroundColor = tintColor.cgColor
        #endif
    }

    private func layoutLayers() {
        let barY = (bounds.height - Self.barHeight) / 2
        withoutImplicitAnimation {
            trackLayer.frame = CGRect(x: 0, y: barY, width: bounds.width, height: Self.barHeight)
            fillLayer.position = CGPoint(x: 0, y: barY + Self.barHeight / 2)
        }
        applyAnchor()
    }

    func setAnchor(_ newAnchor: ProgressAnchor) {
        guard newAnchor != anchor else { return }
        anchor = newAnchor
        applyAnchor()
    }

    /// Places the fill at the anchor's projected fraction and, when moving,
    /// hands Core Animation one linear animation to the full width.
    private func applyAnchor() {
        let width = bounds.width
        guard width > 0 else { return }
        let elapsed = max(0, Date().timeIntervalSince(anchor.date))
        let fractionNow = min(1, max(0, anchor.fraction + anchor.fractionsPerSecond * elapsed))
        fillLayer.removeAnimation(forKey: Self.animationKey)
        withoutImplicitAnimation {
            fillLayer.bounds = CGRect(x: 0, y: 0, width: width * fractionNow, height: Self.barHeight)
        }
        guard anchor.fractionsPerSecond > 0, fractionNow < 1 else { return }
        let animation = CABasicAnimation(keyPath: "bounds.size.width")
        animation.fromValue = width * fractionNow
        animation.toValue = width
        animation.duration = (1 - fractionNow) / anchor.fractionsPerSecond
        animation.timingFunction = CAMediaTimingFunction(name: .linear)
        animation.fillMode = .forwards
        animation.isRemovedOnCompletion = false
        fillLayer.add(animation, forKey: Self.animationKey)
    }

    private func withoutImplicitAnimation(_ changes: () -> Void) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        changes()
        CATransaction.commit()
    }
}
