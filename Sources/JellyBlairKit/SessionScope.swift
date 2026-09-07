import Foundation

/// The objects that live for one signed-in session, built in one place so
/// both platform shells assemble identically. The shells inject each member
/// into the SwiftUI environment, where views look them up by type.
@MainActor
public final class SessionScope {
    public let client: JellyfinClient
    public let catalog: BookCatalog
    public let library: LibraryViewModel
    public let player: PlayerController
    public let connection: ConnectionMonitor

    public init(client: JellyfinClient) {
        self.client = client
        catalog = BookCatalog(client: client)
        library = LibraryViewModel(client: client)
        player = PlayerController(client: client)
        connection = ConnectionMonitor(client: client)
        // A library refresh syncs its snapshots into the existing book
        // models, except the loaded book's, whose position the player owns.
        library.onBooksRefreshed = { [weak catalog, weak player] books in
            catalog?.applySnapshots(books, skippingBookID: player?.book?.id)
        }
    }
}
