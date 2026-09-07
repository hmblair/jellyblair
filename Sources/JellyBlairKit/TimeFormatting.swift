import Foundation

/// Formats a duration in seconds as H:MM:SS, or MM:SS under one hour.
public func formatTime(_ seconds: Double) -> String {
    formatTime(seconds, showZeroHour: false)
}

/// Formats an elapsed time with the total's digit count, so the readout
/// keeps one width throughout playback: the hour shows exactly when the
/// total's does, and zeros pad the leading field to the total's width.
public func formatElapsedTime(_ elapsed: Double, matching total: Double) -> String {
    let text = formatTime(elapsed, showZeroHour: Int(total.rounded()) >= 3600)
    // With the hour matched, both strings have the same shape, so any
    // length difference is missing digits in the leading field.
    let missing = formatTime(total).count - text.count
    guard missing > 0 else { return text }
    return String(repeating: "0", count: missing) + text
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

/// Formats a duration in the locale's units, such as "13h 11m" or "42m".
/// A unit with a zero value is left out, so an exact hour reads "1h".
public func formatHoursMinutes(_ seconds: Double) -> String {
    Duration.seconds(seconds).formatted(.units(allowed: [.hours, .minutes], width: .narrow))
}

/// Formats a byte count in the locale's units, keeping at most three
/// digits, such as "63.5 MB", "147 MB", or "2.38 GB".
public func formatFileSize(_ bytes: Int64) -> String {
    bytes.formatted(.byteCount(style: .file, spellsOutZero: false))
}
