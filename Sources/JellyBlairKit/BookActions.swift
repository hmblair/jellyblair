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

    public var canResetPlayback: Bool {
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

    /// Clears the played mark, the resume position, and the play history on
    /// the server. The loaded book closes first, so playback stops and no
    /// later progress report restores the position.
    public func resetPlayback() {
        Task {
            if isLoaded {
                await player.close()
            }
            await book.resetPlayback()
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

extension BookActions {
    /// The reset, with the question asked before it runs. The explanation
    /// names only the state the book holds now.
    public var resetPlaybackAction: DestructiveAction {
        DestructiveAction(
            question: Text("Reset this book?"),
            explanation: resetExplanation,
            buttonTitle: Text("Reset")
        ) {
            resetPlayback()
        }
    }

    private var resetExplanation: Text {
        if book.isPlayed {
            Text("The resume position is cleared and the book is marked unread.")
        } else {
            Text("The resume position is cleared.")
        }
    }

    /// The download removal, with the question asked before it runs.
    public var removeDownloadAction: DestructiveAction {
        DestructiveAction(
            question: Text("Remove this download?"),
            explanation: Text("The file is deleted from this device."),
            buttonTitle: Text("Remove Download")
        ) {
            book.removeDownload()
        }
    }
}

/// Attaches the book actions as a context menu on a library row, with the
/// confirmation dialog that the menu's destructive items open. A menu
/// closes on its first tap, so the question is a dialog on the row.
public struct BookActionsContextMenu: ViewModifier {
    let book: Book

    @State private var pendingAction: DestructiveAction?

    public func body(content: Content) -> some View {
        content
            .contextMenu {
                BookActionsMenuItems(book: book, pendingAction: $pendingAction)
            }
            .confirmsDestructiveAction($pendingAction)
    }
}

extension View {
    /// Gives a library row the book actions as its context menu.
    public func bookActionsContextMenu(for book: Book) -> some View {
        modifier(BookActionsContextMenu(book: book))
    }
}

/// The actions on one book as menu items, for the library rows' context
/// menus. They mirror the details sheet's rows. The destructive items
/// hand their action to the binding, and the row's dialog asks about it.
public struct BookActionsMenuItems: View {
    let book: Book
    @Binding var pendingAction: DestructiveAction?

    @Environment(PlayerController.self) private var player
    @Environment(ConnectionMonitor.self) private var connection

    public init(book: Book, pendingAction: Binding<DestructiveAction?>) {
        self.book = book
        _pendingAction = pendingAction
    }

    private var actions: BookActions {
        BookActions(book: book, player: player, connection: connection)
    }

    public var body: some View {
        playedItem
        favoriteItem
        downloadItem
        syncItem
        resetItem
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

    /// Opens the reset question.
    private var resetItem: some View {
        Button(role: .destructive) {
            pendingAction = actions.resetPlaybackAction
        } label: {
            destructiveLabel(Text("Reset"), icon: resetPlaybackIcon)
        }
        .disabled(!actions.canResetPlayback)
    }

    /// A menu label in red on both platforms. The phone's menus color the
    /// destructive role themselves, while the Mac's menus keep the plain
    /// menu color and drop view styles, so the red goes into the text and
    /// the image directly.
    private func destructiveLabel(_ title: Text, icon: Icon) -> some View {
        Label {
            #if os(macOS)
            title.foregroundStyle(.red)
            #else
            title
            #endif
        } icon: {
            #if os(macOS)
            icon.destructiveImage
            #else
            icon.plain
            #endif
        }
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
            Button(role: .destructive) {
                pendingAction = actions.removeDownloadAction
            } label: {
                destructiveLabel(Text("Remove Download"), icon: removeDownloadIcon)
            }
        }
    }
}
