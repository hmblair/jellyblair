import Foundation

/// Formats a duration in seconds as H:MM:SS, or MM:SS under one hour.
public func formatTime(_ seconds: Double) -> String {
    let total = Int(seconds.rounded())
    let hours = total / 3600
    let minutes = (total % 3600) / 60
    let secs = total % 60
    guard hours >= 1 else { return String(format: "%d:%02d", minutes, secs) }
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

/// Formats a publish date as its month and year, such as "January 2001".
public func formatPublishDate(_ date: Date) -> String {
    date.formatted(Date.FormatStyle(timeZone: serverTimeZone).year().month(.wide))
}

/// Formats a byte count in the locale's units, keeping at most three
/// digits, such as "63.5 MB", "147 MB", or "2.38 GB".
public func formatFileSize(_ bytes: Int64) -> String {
    bytes.formatted(.byteCount(style: .file, spellsOutZero: false))
}

/// Formats a completed and a total byte count, such as "500 KB/381.9 MB",
/// each in the file sizes' own system format.
public func formatFileSizeProgress(_ completed: Int64, of total: Int64) -> String {
    "\(formatFileSize(completed))/\(formatFileSize(total))"
}
