import SwiftUI

/// Sheet with the book's file details and the download action. Opens from
/// the book screen's title-bar info button. The rows share one form; each
/// platform wraps it in its own chrome, like the settings screens.
public struct BookFileInfoSheet: View {
    let book: Book

    @Environment(PlayerController.self) private var player
    @Environment(ConnectionMonitor.self) private var connection

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
        MacSheet(title: Text("File Information")) {
            form
            actionRow
                .padding(.horizontal, sheetEdgePadding)
        }
    }
    #else
    private var phoneBody: some View {
        PhoneSheet(title: Text("File Information")) {
            form
                .safeAreaInset(edge: .bottom) {
                    actionRow
                        .padding(.horizontal, sheetEdgePadding)
                        .padding(.bottom, 8)
                }
        }
    }
    #endif

    private var form: some View {
        Form {
            Section {
                detailRows
            }
        }
        #if os(macOS)
        .formStyle(.grouped)
        #endif
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

    /// The sheet's actions on one row, mirrored by the library rows'
    /// context menus. The error and the progress bar sit above the row.
    private var actionRow: some View {
        VStack(spacing: 12) {
            errorLine
            downloadProgress
            HStack(spacing: 12) {
                downloadButton
                Button("Refresh") {
                    actions.refreshMetadata()
                }
                .buttonStyle(.borderedProminent)
                .disabled(!actions.canRefreshMetadata)
                DestructiveActionButton(requiresConfirmation: false) {
                    actions.resetPlayback()
                } label: {
                    Text("Reset")
                }
                .disabled(!actions.canResetPlayback)
            }
        }
    }

    @ViewBuilder
    private var downloadButton: some View {
        switch book.downloadState {
        case .notDownloaded:
            Button("Download") {
                book.download()
            }
            .buttonStyle(.borderedProminent)
            .disabled(!actions.canDownload)
        case .downloading:
            DestructiveActionButton(requiresConfirmation: false) {
                book.cancelDownload()
            } label: {
                Text("Cancel")
            }
        case .downloaded:
            DestructiveActionButton {
                book.removeDownload()
            } label: {
                Text("Remove")
            }
        }
    }

    @ViewBuilder
    private var downloadProgress: some View {
        if case .downloading(let progress) = book.downloadState {
            // An unknown fraction draws as an empty bar, never as the
            // indeterminate style: the Mac's linear bar keeps the
            // indeterminate bounce even after real fractions arrive.
            ProgressView(value: progress ?? 0)
                .progressViewStyle(.linear)
        }
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
