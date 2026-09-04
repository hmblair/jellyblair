import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

/// Keeps the display from sleeping while the flag is on and the view is on
/// screen. The phone disables the idle timer; the Mac holds a display-sleep
/// activity assertion.
private struct KeepsScreenAwake: ViewModifier {
    let isOn: Bool
    let reason: String

    #if canImport(AppKit)
    @State private var activity: NSObjectProtocol?
    #endif

    func body(content: Content) -> some View {
        content
            .onChange(of: isOn, initial: true) { _, on in
                setAwake(on)
            }
            .onDisappear {
                setAwake(false)
            }
    }

    private func setAwake(_ on: Bool) {
        #if canImport(UIKit)
        UIApplication.shared.isIdleTimerDisabled = on
        #else
        if on, activity == nil {
            activity = ProcessInfo.processInfo.beginActivity(options: .idleDisplaySleepDisabled, reason: reason)
        } else if !on, let activity {
            ProcessInfo.processInfo.endActivity(activity)
            self.activity = nil
        }
        #endif
    }
}

public extension View {
    /// Keeps the display awake while the flag is on and the view is on screen.
    func keepsScreenAwake(_ isOn: Bool, reason: String) -> some View {
        modifier(KeepsScreenAwake(isOn: isOn, reason: reason))
    }
}
