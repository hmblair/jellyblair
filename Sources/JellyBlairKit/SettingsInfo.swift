import SwiftUI

/// The settings' About section: the number of books, the space the app
/// takes on this device, and the app version.
public struct SettingsInfoSection: View {
    @State private var info: StorageInfo?

    public init() {}

    public var body: some View {
        Section("About") {
            LabeledContent("Books", value: info.map { String($0.bookCount) } ?? "")
            LabeledContent("Cache Size", value: info.map { formatFileSize($0.cacheBytes) } ?? "")
            LabeledContent("Version", value: Self.versionText)
        }
        .task {
            info = await StorageInfo.gathered()
        }
    }

    /// The app version with its build number, from the bundle, where the
    /// build stamps them out of the VERSION file and the commit count. A
    /// bare development binary has neither.
    private static var versionText: String {
        guard let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String else { return "dev" }
        guard let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String else { return version }
        return "\(version) (\(build))"
    }
}

/// What the About section reports. The book count comes from the cached
/// library snapshot, which every successful refresh rewrites. The cache
/// size is everything the app keeps on disk, downloads included.
private struct StorageInfo {
    let bookCount: Int
    let cacheBytes: Int64

    /// Reads the count and size off the main thread, since the downloaded
    /// books can be gigabytes to walk.
    static func gathered() async -> StorageInfo {
        await Task.detached { gather() }.value
    }

    private static func gather() -> StorageInfo {
        StorageInfo(
            bookCount: LibraryStore().load().count,
            cacheBytes: directorySize(DataDirectory.root)
        )
    }

    /// The total size of the files under the directory.
    private static func directorySize(_ directory: URL) -> Int64 {
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .fileSizeKey]
        guard let enumerator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: Array(keys)) else {
            return 0
        }
        var bytes: Int64 = 0
        for case let file as URL in enumerator {
            guard let values = try? file.resourceValues(forKeys: keys), values.isRegularFile == true else { continue }
            bytes += Int64(values.fileSize ?? 0)
        }
        return bytes
    }
}
