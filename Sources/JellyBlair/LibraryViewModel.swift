import Foundation
import Observation

/// Signs in on launch and holds the audiobook list.
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
            try await client.authenticate()
            books = try await client.fetchAudiobooks()
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }
}
