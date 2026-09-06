import Foundation

/// Returns the app's directory in Application Support, creating it if needed.
func jellyBlairDataDirectory() -> URL {
    let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    let directory = base.appendingPathComponent("JellyBlair")
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
}

/// Reduces a server-provided value to alphanumerics, dashes, and
/// underscores, so it cannot carry path syntax into a file name. Jellyfin
/// identifiers pass through unchanged.
func sanitizedFileComponent(_ value: String) -> String {
    let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
    return String(String.UnicodeScalarView(value.unicodeScalars.filter { allowed.contains($0) }))
}
