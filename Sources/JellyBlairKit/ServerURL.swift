import Foundation

/// Parses text into a server URL. Every server URL in the app comes through
/// here, at login and at session load, so the client can compose request
/// URLs on top of a value that is known to be well formed.
enum ServerURL {
    /// The parsed URL, or nil when the text does not name a web server.
    /// A bare host gets https as its scheme.
    static func parse(_ text: String) -> URL? {
        var trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if !trimmed.contains("://") {
            trimmed = "https://" + trimmed
        }
        guard
            let url = URL(string: trimmed),
            let scheme = url.scheme?.lowercased(),
            scheme == "http" || scheme == "https",
            url.host != nil
        else { return nil }
        return url
    }
}
