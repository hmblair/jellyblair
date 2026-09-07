import Foundation

/// The app's directories inside Application Support. Every accessor creates
/// its directory, so a caller can write into the result at once.
enum DataDirectory {
    /// Holds everything the app keeps on disk, including the library and
    /// chapter files.
    static var root: URL {
        created(applicationSupport.appendingPathComponent("JellyBlair"))
    }

    /// Holds the downloaded books. Backups leave it out, because every book
    /// in it can be downloaded again from the server.
    static var downloads: URL {
        excludedFromBackup(created(root.appendingPathComponent("downloads")))
    }

    /// Holds the fetched transcripts, one file for each book.
    static var lyrics: URL {
        created(root.appendingPathComponent("lyrics"))
    }

    /// Holds the fetched cover images, one file for each book.
    static var covers: URL {
        created(root.appendingPathComponent("covers"))
    }

    private static var applicationSupport: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    }

    /// Creates the directory if it is absent, then returns it.
    private static func created(_ url: URL) -> URL {
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Marks the directory so that device backups leave it out, then returns it.
    private static func excludedFromBackup(_ url: URL) -> URL {
        var url = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? url.setResourceValues(values)
        return url
    }
}

/// Reduces a server-provided value to alphanumerics, dashes, and
/// underscores, so it cannot carry path syntax into a file name. Jellyfin
/// identifiers pass through unchanged.
func sanitizedFileComponent(_ value: String) -> String {
    let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
    return String(String.UnicodeScalarView(value.unicodeScalars.filter { allowed.contains($0) }))
}
