import Foundation
import Observation

/// Holds the audiobook list.
@MainActor
@Observable
final class LibraryViewModel {
    let client: JellyfinClient

    private(set) var books: [Book] = []
    private(set) var isLoading = true
    private(set) var errorMessage: String?

    init(client: JellyfinClient) {
        self.client = client
    }

    func load() async {
        isLoading = true
        errorMessage = nil
        do {
            books = try await client.fetchAudiobooks()
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }
}
