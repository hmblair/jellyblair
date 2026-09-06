import SwiftUI

/// The skip buttons' intervals, stored app-wide so the settings screens
/// can change them outside the player's scope. The backward and forward
/// intervals are independent.
public enum SkipIntervals {
    /// The choosable intervals: SF Symbols provides numbered skip arrows
    /// only for these values.
    public static let options: [Double] = [5, 10, 15, 30, 45, 60, 75, 90]

    public static let defaultSeconds: Double = 30
    public static let backKey = "skipBackSeconds"
    public static let forwardKey = "skipForwardSeconds"

    /// The stored backward interval.
    public static var back: Double { value(forKey: backKey) }

    /// The stored forward interval.
    public static var forward: Double { value(forKey: forwardKey) }

    private static func value(forKey key: String) -> Double {
        let stored = UserDefaults.standard.double(forKey: key)
        return stored > 0 ? stored : defaultSeconds
    }
}

/// The two skip interval pickers, shared by both platforms' settings
/// screens.
public struct SkipIntervalSettings: View {
    @AppStorage(SkipIntervals.backKey) private var backSeconds: Double = SkipIntervals.defaultSeconds
    @AppStorage(SkipIntervals.forwardKey) private var forwardSeconds: Double = SkipIntervals.defaultSeconds

    public init() {}

    public var body: some View {
        intervalPicker("Skip Back", selection: $backSeconds)
        intervalPicker("Skip Forward", selection: $forwardSeconds)
    }

    private func intervalPicker(_ title: LocalizedStringKey, selection: Binding<Double>) -> some View {
        Picker(title, selection: selection) {
            ForEach(SkipIntervals.options, id: \.self) { seconds in
                Text("\(Int(seconds)) seconds").tag(seconds)
            }
        }
    }
}
