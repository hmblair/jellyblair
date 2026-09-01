import AppKit
import SwiftUI

/// Serves book covers from memory, then disk, then the network.
/// Covers seen once stay available offline and across scrolling.
@MainActor
final class CoverImageLoader {
    static let shared = CoverImageLoader()

    private var memory: [String: NSImage] = [:]

    private var directory: URL {
        jellyBlairDataDirectory().appendingPathComponent("covers")
    }

    func image(for bookID: String, from url: URL) async -> NSImage? {
        guard !bookID.isEmpty else { return nil }
        if let cached = memory[bookID] {
            return cached
        }
        let fileURL = directory.appendingPathComponent(bookID)
        if let image = NSImage(contentsOf: fileURL) {
            memory[bookID] = image
            return image
        }
        guard
            let (data, response) = try? await URLSession.shared.data(from: url),
            (response as? HTTPURLResponse)?.statusCode == 200,
            let image = NSImage(data: data)
        else { return nil }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? data.write(to: fileURL)
        memory[bookID] = image
        return image
    }
}

/// Displays a book cover through the cache, with a neutral placeholder.
struct BookCoverImage: View {
    let bookID: String
    let url: URL
    let contentMode: ContentMode

    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image).resizable().aspectRatio(contentMode: contentMode)
            } else {
                Color.secondary.opacity(0.2)
            }
        }
        .task(id: bookID) {
            image = await CoverImageLoader.shared.image(for: bookID, from: url)
        }
    }
}
