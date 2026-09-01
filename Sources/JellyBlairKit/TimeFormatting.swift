import Foundation

/// Formats a duration in seconds as H:MM:SS.
public func formatTime(_ seconds: Double) -> String {
    let total = Int(seconds.rounded())
    let hours = total / 3600
    let minutes = (total % 3600) / 60
    let secs = total % 60
    return String(format: "%d:%02d:%02d", hours, minutes, secs)
}

/// Formats a playback speed as "1×" or "1.5×".
public func formatPlaybackSpeed(_ speed: Double) -> String {
    String(format: "%g×", speed)
}
