import SwiftUI

/// Serves book covers from memory, then disk, then the network.
/// Covers seen once stay available offline and across scrolling.
@Observable
@MainActor
public final class CoverImageLoader {
    public static let shared = CoverImageLoader()

    private var memory: [String: PlatformImage] = [:]

    private func fileURL(for bookID: String) -> URL {
        DataDirectory.covers.appendingPathComponent(sanitizedFileComponent(bookID))
    }

    /// Returns the cover already held in memory, without any loading.
    public func cachedImage(for bookID: String) -> PlatformImage? {
        memory[bookID]
    }

    public func image(for bookID: String, from url: URL) async -> PlatformImage? {
        guard !bookID.isEmpty else { return nil }
        if let cached = memory[bookID] {
            return cached
        }
        if let image = PlatformImage(contentsOfFile: fileURL(for: bookID).path) {
            memory[bookID] = image
            return image
        }
        return await download(for: bookID, from: url)
    }

    /// Downloads the cover again and replaces both cache levels.
    /// A failed download keeps the cover the cache already holds.
    public func refresh(for bookID: String, from url: URL) async {
        guard !bookID.isEmpty else { return }
        _ = await download(for: bookID, from: url)
    }

    private func download(for bookID: String, from url: URL) async -> PlatformImage? {
        guard
            let (data, response) = try? await URLSession.shared.data(from: url),
            (response as? HTTPURLResponse)?.statusCode == 200,
            let image = PlatformImage(data: data)
        else { return nil }
        try? data.write(to: fileURL(for: bookID))
        memory[bookID] = image
        return image
    }
}

/// Displays a book cover through the cache, with a neutral placeholder.
/// It reads the image straight from the loader, so a refreshed cover
/// appears everywhere without a reload.
public struct BookCoverImage: View {
    let bookID: String
    let url: URL
    let contentMode: ContentMode

    public init(bookID: String, url: URL, contentMode: ContentMode) {
        self.bookID = bookID
        self.url = url
        self.contentMode = contentMode
    }

    public var body: some View {
        Group {
            if let image = CoverImageLoader.shared.cachedImage(for: bookID) {
                Image(platformImage: image).resizable().aspectRatio(contentMode: contentMode)
            } else {
                Color.secondary.opacity(0.2)
            }
        }
        .task(id: bookID) {
            _ = await CoverImageLoader.shared.image(for: bookID, from: url)
        }
    }
}
