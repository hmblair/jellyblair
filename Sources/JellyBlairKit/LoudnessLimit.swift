import Foundation
import SwiftUI

/// The loudness limiter's ceiling, stored app-wide so the settings screens
/// can change it outside the player's scope. A ceiling at full scale turns
/// the limiter off, since no sample can rise above it.
public enum LoudnessLimit {
    public static let ceilingKey = "loudnessLimitCeilingDecibels"

    /// The ceiling in decibels below full scale, and the range the slider
    /// offers.
    public static let defaultCeilingDecibels: Double = -12
    public static let ceilingRange: ClosedRange<Double> = -30...0

    /// The stored ceiling.
    public static var ceilingDecibels: Double {
        UserDefaults.standard.object(forKey: ceilingKey) as? Double ?? defaultCeilingDecibels
    }
}

/// The limiter's ceiling slider, shared by both platforms' settings screens.
public struct LoudnessLimitSettings: View {
    @AppStorage(LoudnessLimit.ceilingKey) private var ceilingDecibels = LoudnessLimit.defaultCeilingDecibels

    public init() {}

    public var body: some View {
        VStack(alignment: .leading) {
            LabeledContent("Limiter Ceiling", value: "\(Int(ceilingDecibels)) dB")
            Slider(value: $ceilingDecibels, in: LoudnessLimit.ceilingRange, step: 1)
        }
    }
}
