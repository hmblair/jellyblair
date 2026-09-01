import Foundation

/// Returns the app's directory in Application Support, creating it if needed.
func jellyBlairDataDirectory() -> URL {
    let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    let directory = base.appendingPathComponent("JellyBlair")
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
}
