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
        let catalog = BookCatalog(client: client)
        self.catalog = catalog
        library = LibraryViewModel(client: client)
        player = PlayerController(client: client, catalog: catalog)
        connection = ConnectionMonitor(client: client)
    }
}
