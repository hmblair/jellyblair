import Foundation

/// Parses one of the server's timestamps.
func parseServerDate(_ text: String) -> Date? {
    serverDateFormatter.date(from: withoutFractionalSeconds(text))
}

private let serverDateFormatter: ISO8601DateFormatter = {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime]
    return formatter
}()

/// Removes a timestamp's fractional seconds, which the server writes with
/// more digits than the parser accepts.
private func withoutFractionalSeconds(_ text: String) -> String {
    guard let start = text.firstIndex(of: ".") else { return text }
    let end = text[start...].firstIndex { "Z+-".contains($0) } ?? text.endIndex
    return text.replacingCharacters(in: start..<end, with: "")
}
