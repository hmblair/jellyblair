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

/// A track-and-fill progress bar with a knob on the fill's end, whose motion
/// is a single linear Core Animation animation to the end of the range. The
/// render server moves the bar; the app only touches it when the anchor
/// changes. The knob grows while the user scrubs.
struct AnimatedProgressBar {
    var anchor: ProgressAnchor
    var isScrubbing: Bool
}

#if canImport(AppKit)
extension AnimatedProgressBar: NSViewRepresentable {
    func makeNSView(context: Context) -> ProgressBarLayerView {
        ProgressBarLayerView()
    }

    func updateNSView(_ view: ProgressBarLayerView, context: Context) {
        view.setAnchor(anchor)
        view.setScrubbing(isScrubbing)
    }
}
#else
extension AnimatedProgressBar: UIViewRepresentable {
    func makeUIView(context: Context) -> ProgressBarLayerView {
        ProgressBarLayerView()
    }

    func updateUIView(_ view: ProgressBarLayerView, context: Context) {
        view.setAnchor(anchor)
        view.setScrubbing(isScrubbing)
    }
}
#endif

/// The layer-backed platform view behind AnimatedProgressBar.
final class ProgressBarLayerView: PlatformNativeView {
    private static let barHeight: CGFloat = 9
    private static let knobDiameter: CGFloat = 14
    private static let scrubbingKnobDiameter: CGFloat = 18
    private static let knobShadowRadius: CGFloat = 2
    private static let knobShadowOpacity: Float = 0.3
    private static let animationKey = "progress"

    private let trackLayer = CALayer()
    private let fillLayer = CALayer()
    private let knobLayer = CALayer()
    private var anchor = ProgressAnchor(fraction: 0, fractionsPerSecond: 0, date: .distantPast)
    private var isScrubbing = false

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
        setUpKnobLayer()
        backingLayer?.addSublayer(trackLayer)
        backingLayer?.addSublayer(fillLayer)
        backingLayer?.addSublayer(knobLayer)
        applyColors()
        #if canImport(UIKit)
        registerForTraitChanges(UITraitCollection.systemTraitsAffectingColorAppearance) { (view: ProgressBarLayerView, _: UITraitCollection) in
            view.applyColors()
        }
        #endif
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

    override func tintColorDidChange() {
        super.tintColorDidChange()
        applyColors()
    }
    #endif

    /// Sets up the knob as a white circle with a soft shadow. White in both
    /// appearances keeps it distinct from the accent-colored fill under any
    /// accent, and the shadow separates it from the track in light mode.
    private func setUpKnobLayer() {
        let bounds = CGRect(x: 0, y: 0, width: Self.knobDiameter, height: Self.knobDiameter)
        knobLayer.bounds = bounds
        knobLayer.cornerRadius = Self.knobDiameter / 2
        knobLayer.backgroundColor = CGColor(gray: 1, alpha: 1)
        knobLayer.shadowColor = CGColor(gray: 0, alpha: 1)
        knobLayer.shadowOpacity = Self.knobShadowOpacity
        knobLayer.shadowRadius = Self.knobShadowRadius
        knobLayer.shadowOffset = .zero
        knobLayer.shadowPath = CGPath(ellipseIn: bounds, transform: nil)
    }

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
            knobLayer.position = CGPoint(x: knobLayer.position.x, y: barY + Self.barHeight / 2)
        }
        applyAnchor()
    }

    func setAnchor(_ newAnchor: ProgressAnchor) {
        guard newAnchor != anchor else { return }
        anchor = newAnchor
        applyAnchor()
    }

    /// Grows the knob to the hit area's height while scrubbing. The change
    /// takes the layer's implicit animation, so it runs only when the state
    /// changes.
    func setScrubbing(_ newValue: Bool) {
        guard newValue != isScrubbing else { return }
        isScrubbing = newValue
        let scale = isScrubbing ? Self.scrubbingKnobDiameter / Self.knobDiameter : 1
        knobLayer.transform = CATransform3DMakeScale(scale, scale, 1)
    }

    /// Places the fill's end and the knob at the anchor's projected fraction
    /// and, when moving, hands Core Animation one linear animation each to
    /// the full width, so the two stay together.
    private func applyAnchor() {
        let width = bounds.width
        guard width > 0 else { return }
        let elapsed = max(0, Date().timeIntervalSince(anchor.date))
        let fractionNow = min(1, max(0, anchor.fraction + anchor.fractionsPerSecond * elapsed))
        let fillEnd = width * fractionNow
        fillLayer.removeAnimation(forKey: Self.animationKey)
        knobLayer.removeAnimation(forKey: Self.animationKey)
        withoutImplicitAnimation {
            fillLayer.bounds = CGRect(x: 0, y: 0, width: fillEnd, height: Self.barHeight)
            knobLayer.position.x = fillEnd
        }
        guard anchor.fractionsPerSecond > 0, fractionNow < 1 else { return }
        let duration = (1 - fractionNow) / anchor.fractionsPerSecond
        fillLayer.add(
            linearAnimation(keyPath: "bounds.size.width", from: fillEnd, to: width, duration: duration),
            forKey: Self.animationKey
        )
        knobLayer.add(
            linearAnimation(keyPath: "position.x", from: fillEnd, to: width, duration: duration),
            forKey: Self.animationKey
        )
    }

    /// Builds a linear animation that holds its end value once it finishes.
    private func linearAnimation(keyPath: String, from: CGFloat, to: CGFloat, duration: TimeInterval) -> CABasicAnimation {
        let animation = CABasicAnimation(keyPath: keyPath)
        animation.fromValue = from
        animation.toValue = to
        animation.duration = duration
        animation.timingFunction = CAMediaTimingFunction(name: .linear)
        animation.fillMode = .forwards
        animation.isRemovedOnCompletion = false
        return animation
    }

    private func withoutImplicitAnimation(_ changes: () -> Void) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        changes()
        CATransaction.commit()
    }
}
