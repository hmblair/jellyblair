import Foundation

/// Formats a duration in seconds as H:MM:SS, or MM:SS under one hour.
public func formatTime(_ seconds: Double) -> String {
    formatTime(seconds, showZeroHour: false)
}

/// Formats an elapsed time, showing an hour exactly when the total does,
/// so the readout keeps one width throughout playback.
public func formatElapsedTime(_ elapsed: Double, matching total: Double) -> String {
    formatTime(elapsed, showZeroHour: Int(total.rounded()) >= 3600)
}

private func formatTime(_ seconds: Double, showZeroHour: Bool) -> String {
    let total = Int(seconds.rounded())
    let hours = total / 3600
    let minutes = (total % 3600) / 60
    let secs = total % 60
    guard hours >= 1 || showZeroHour else { return String(format: "%d:%02d", minutes, secs) }
    return String(format: "%d:%02d:%02d", hours, minutes, secs)
}

/// Formats a playback speed as "1×" or "1.5×".
public func formatPlaybackSpeed(_ speed: Double) -> String {
    String(format: "%g×", speed)
}

/// Formats a duration as "13h 11m", or "42m" under one hour.
public func formatHoursMinutes(_ seconds: Double) -> String {
    let minutes = Int((seconds / 60).rounded())
    guard minutes >= 60 else { return "\(minutes)m" }
    return "\(minutes / 60)h \(minutes % 60)m"
}

/// Formats a byte count with at most three digits, like "63.5 MB",
/// "147 MB", or "2.38 GB".
public func formatFileSize(_ bytes: Int64) -> String {
    let units = ["bytes", "KB", "MB", "GB", "TB"]
    var value = Double(bytes)
    var index = 0
    while value >= 1000, index + 1 < units.count {
        value /= 1000
        index += 1
    }
    let wholeDigits = value >= 100 ? 3 : (value >= 10 ? 2 : 1)
    return String(format: "%.\(3 - wholeDigits)f %@", value, units[index])
}
