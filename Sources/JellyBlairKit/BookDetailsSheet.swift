import SwiftUI

/// Sheet with the book's state toggles, file details, and download
/// action. Opens from the book screen's title-bar info button. The rows
/// share one form; each platform wraps it in its own chrome, like the
/// settings screens.
public struct BookDetailsSheet: View {
    let book: Book

    @Environment(PlayerController.self) private var player
    @Environment(ConnectionMonitor.self) private var connection

    /// Each destructive row's action while its dialog asks about it. The
    /// dialog anchors to the row that opened it, so each row keeps its own.
    @State private var pendingRemoval: DestructiveAction?
    @State private var pendingReset: DestructiveAction?

    public init(book: Book) {
        self.book = book
    }

    public var body: some View {
        #if os(macOS)
        macBody
        #else
        phoneBody
        #endif
    }

    #if os(macOS)
    private var macBody: some View {
        MacSheet(title: Text("Details")) {
            form
        }
    }
    #else
    private var phoneBody: some View {
        PhoneSheet(title: Text("Details")) {
            form
        }
    }
    #endif

    private var form: some View {
        Form {
            Section {
                playedRow
                favoriteRow
                downloadRow
                errorLine
            }
            Section {
                detailRows
            }
            Section {
                syncRow
                resetRow
            }
        }
        #if os(macOS)
        .formStyle(.grouped)
        #endif
    }

    private var favoriteRow: some View {
        toggleRow(
            title: book.isFavorite ? Text("Favorite") : Text("Not Favorite"),
            icon: book.isFavorite ? favoriteIcon : notFavoriteIcon,
            isOn: book.isFavorite,
            isEnabled: actions.canToggleFavorite
        ) {
            actions.toggleFavorite()
        }
    }

    private var playedRow: some View {
        toggleRow(
            title: book.isPlayed ? Text("Read") : Text("Unread"),
            icon: book.isPlayed ? readIcon : unreadIcon,
            isOn: book.isPlayed,
            isEnabled: actions.canTogglePlayed
        ) {
            actions.togglePlayed()
        }
    }

    /// The download state as a row like the toggles above it: tapping
    /// downloads, cancels, or removes, by the state it shows.
    @ViewBuilder
    private var downloadRow: some View {
        switch book.downloadState {
        case .notDownloaded:
            toggleRow(
                title: Text("Not Downloaded"),
                icon: notDownloadedIcon,
                isOn: false,
                isEnabled: actions.canDownload
            ) {
                book.download()
            }
        case .downloading(let fraction):
            toggleRow(
                title: Text("Downloading"),
                value: downloadProgressText(fraction),
                icon: notDownloadedIcon,
                isOn: false,
                isEnabled: true
            ) {
                book.cancelDownload()
            }
        case .downloaded:
            toggleRow(
                title: Text("Downloaded"),
                icon: downloadedIcon,
                isOn: true,
                isEnabled: true
            ) {
                pendingRemoval = actions.removeDownloadAction
            }
            .confirmsDestructiveAction($pendingRemoval)
        }
    }

    /// The downloaded and total sizes while both are known, such as
    /// "12.3/381.9 MB", for the downloading row's value.
    private func downloadProgressText(_ fraction: Double?) -> Text? {
        guard let fraction, let total = book.fileSizeBytes else { return nil }
        return Text(formatFileSizeProgress(Int64(fraction * Double(total)), of: total))
    }

    /// One tappable state row: the state's name behind its icon, which
    /// shows the accent while the state is on, like the filter menu's
    /// choices. The plain button style keeps the row looking like the
    /// detail rows on both platforms, and the optional value reads on the
    /// trailing side like theirs. A tint colors the whole row, for a
    /// destructive row. A busy row spins its icon while its action runs.
    private func toggleRow(title: Text, value: Text? = nil, icon: Icon, isOn: Bool, isEnabled: Bool, tint: Color? = nil, isBusy: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            LabeledContent {
                value
            } label: {
                Label {
                    title
                } icon: {
                    if isOn {
                        icon.accented
                    } else {
                        // The explicit style overrides the phone form's own
                        // accent tint on label icons.
                        icon.plain
                            .foregroundStyle(tint ?? Color.primary)
                            .symbolEffect(.rotate, isActive: isBusy)
                    }
                }
                .foregroundStyle(tint ?? Color.primary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
    }

    @ViewBuilder
    private var detailRows: some View {
        if let format = book.container {
            detailRow(icon: formatIcon, label: Text("Format")) {
                Text(verbatim: format.uppercased())
            }
        }
        if let line = codecLine {
            detailRow(icon: bitrateIcon, label: Text("Codec")) {
                line
            }
        }
        if let bytes = book.fileSizeBytes {
            detailRow(icon: fileSizeIcon, label: Text("Size")) {
                Text(formatFileSize(bytes))
            }
        }
        detailRow(icon: durationIcon, label: Text("Duration")) {
            Text(formatHoursMinutes(book.runTimeSeconds))
        }
    }

    /// The bitrate and codec as one value, such as "68 kbps AAC", from
    /// whichever parts the server reports.
    private var codecLine: Text? {
        switch (book.bitrateKbps, book.codec?.uppercased()) {
        case (let kbps?, let codec?):
            Text("\(kbps) kbps \(codec)")
        case (let kbps?, nil):
            Text("\(kbps) kbps")
        case (nil, let codec?):
            Text(verbatim: codec)
        case (nil, nil):
            nil
        }
    }

    private func detailRow(icon: Icon, label: Text, @ViewBuilder value: () -> some View) -> some View {
        LabeledContent {
            value()
        } label: {
            Label {
                label
            } icon: {
                // The explicit style overrides the phone form's own accent
                // tint on label icons.
                icon.plain
                    .foregroundStyle(.primary)
            }
        }
    }

    private var actions: BookActions {
        BookActions(book: book, player: player, connection: connection)
    }

    /// Re-fetches the book's metadata from the server, as a row like the
    /// state rows above it, mirrored by the library rows' context menus.
    /// The value shows when the record was last fetched.
    private var syncRow: some View {
        toggleRow(
            title: Text("Sync"),
            value: book.lastSyncedDate.map { Text($0, format: .dateTime.day().month().year().hour().minute()) },
            icon: refreshMetadataIcon,
            isOn: false,
            isEnabled: actions.canRefreshMetadata,
            isBusy: book.isSyncing
        ) {
            actions.refreshMetadata()
        }
    }

    /// Clears the book's playback state on the server, as a row under the
    /// sync row. The tap opens the reset question.
    private var resetRow: some View {
        toggleRow(
            title: Text("Reset"),
            icon: resetPlaybackIcon,
            isOn: false,
            isEnabled: actions.canResetPlayback,
            tint: .red
        ) {
            pendingReset = actions.resetPlaybackAction
        }
        .confirmsDestructiveAction($pendingReset)
    }

    /// The last download failure, until a retry starts.
    @ViewBuilder
    private var errorLine: some View {
        if let message = book.downloadErrorMessage {
            Text(message)
                .font(.callout)
                .foregroundStyle(.red)
                .multilineTextAlignment(.center)
        }
    }

}
