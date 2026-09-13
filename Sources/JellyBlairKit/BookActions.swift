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
        connection.isServerReachable
    }

    public var canResetPlayback: Bool {
        connection.isServerReachable && book.isStarted
    }

    /// Re-reads everything the server and the file know about this book: the
    /// cover, the chapter list, the transcript, and the record with its
    /// resume position.
    public func refreshMetadata() {
        Task {
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

    /// Resets the book: the loaded book closes first, so playback stops,
    /// then the position returns to zero here and on the server.
    public func resetPlayback() {
        Task {
            if isLoaded {
                await player.close()
            }
            await book.resetPlayback()
        }
    }
}

/// The actions on one book as menu items, for the library rows' context
/// menus. They mirror the file information sheet's buttons.
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
        downloadItem
        Button {
            actions.refreshMetadata()
        } label: {
            Label {
                Text("Refresh Metadata")
            } icon: {
                refreshMetadataIcon.plain
            }
        }
        .disabled(!actions.canRefreshMetadata)
        Button {
            actions.resetPlayback()
        } label: {
            Label {
                Text("Reset Playback")
            } icon: {
                resetPlaybackIcon.plain
            }
        }
        .disabled(!actions.canResetPlayback)
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
