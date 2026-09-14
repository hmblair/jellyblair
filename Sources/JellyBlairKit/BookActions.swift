import SwiftUI

/// The actions on one book and their enabling rules, shared by the file
/// information sheet's buttons and the library rows' context menus.
@MainActor
public struct BookActions {
    private let book: Book
    private let player: PlayerController
    private let connection: ConnectionMonitor

    public init(book: Book, player: PlayerController, connection: ConnectionMonitor) {
        self.book = book
        self.player = player
        self.connection = connection
    }

    private var isLoaded: Bool {
        player.book?.id == book.id
    }

    public var canDownload: Bool {
        connection.isServerReachable
    }

    public var canRefreshMetadata: Bool {
        connection.isServerReachable && !book.isSyncing
    }

    public var canToggleFavorite: Bool {
        connection.isServerReachable
    }

    public var canTogglePlayed: Bool {
        connection.isServerReachable
    }

    /// Flips the favorite mark on the server.
    public func toggleFavorite() {
        Task {
            await book.toggleFavorite()
        }
    }

    /// Flips the played mark. The server clears the resume position with
    /// either flip, so the loaded book closes first and playback stops.
    public func togglePlayed() {
        Task {
            if isLoaded {
                await player.close()
            }
            await book.togglePlayed()
        }
    }

    /// Re-reads everything the server and the file know about this book: the
    /// cover, the chapter list, the transcript, and the record with its
    /// resume position. The book shows as syncing throughout.
    public func refreshMetadata() {
        guard !book.isSyncing else { return }
        book.isSyncing = true
        Task {
            defer { book.isSyncing = false }
            await CoverImageLoader.shared.refresh(for: book.id, from: book.coverURL)
            if isLoaded {
                await player.refreshChapters()
                await player.refreshArtwork()
            } else {
                await book.refreshChapters()
            }
            await book.refreshLyrics()
            await book.refreshFromServer()
        }
    }
}

/// The actions on one book as menu items, for the library rows' context
/// menus. They mirror the details sheet's rows.
public struct BookActionsMenuItems: View {
    let book: Book

    @Environment(PlayerController.self) private var player
    @Environment(ConnectionMonitor.self) private var connection

    public init(book: Book) {
        self.book = book
    }

    private var actions: BookActions {
        BookActions(book: book, player: player, connection: connection)
    }

    public var body: some View {
        playedItem
        favoriteItem
        downloadItem
        syncItem
    }

    /// Flips the read mark, named and pictured by the state it moves to.
    private var playedItem: some View {
        Button {
            actions.togglePlayed()
        } label: {
            Label {
                book.isPlayed ? Text("Mark Unread") : Text("Mark Read")
            } icon: {
                (book.isPlayed ? unreadIcon : readIcon).plain
            }
        }
        .disabled(!actions.canTogglePlayed)
    }

    /// Flips the favorite mark, named and pictured by the state it moves
    /// to.
    private var favoriteItem: some View {
        Button {
            actions.toggleFavorite()
        } label: {
            Label {
                book.isFavorite ? Text("Mark Not Favorite") : Text("Mark Favorite")
            } icon: {
                (book.isFavorite ? notFavoriteIcon : favoriteIcon).plain
            }
        }
        .disabled(!actions.canToggleFavorite)
    }

    private var syncItem: some View {
        Button {
            actions.refreshMetadata()
        } label: {
            Label {
                Text("Sync")
            } icon: {
                refreshMetadataIcon.plain
            }
        }
        .disabled(!actions.canRefreshMetadata)
    }

    @ViewBuilder
    private var downloadItem: some View {
        switch book.downloadState {
        case .notDownloaded:
            Button {
                book.download()
            } label: {
                Label {
                    Text("Download")
                } icon: {
                    downloadedIcon.plain
                }
            }
            .disabled(!actions.canDownload)
        case .downloading:
            Button {
                book.cancelDownload()
            } label: {
                Label {
                    Text("Cancel Download")
                } icon: {
                    cancelDownloadIcon.plain
                }
            }
        case .downloaded:
            Button {
                book.removeDownload()
            } label: {
                Label {
                    Text("Remove Download")
                } icon: {
                    removeDownloadIcon.plain
                }
            }
        }
    }
}
