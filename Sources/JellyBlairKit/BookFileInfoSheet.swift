import SwiftUI

/// Sheet with the book's file details and the download action. Opens from
/// the book screen's title-bar info button. The rows share one form; each
/// platform wraps it in its own chrome, like the settings screens.
public struct BookFileInfoSheet: View {
    let book: Book

    @Environment(ConnectionMonitor.self) private var connection
    @Environment(\.dismiss) private var dismiss

    /// Removal asks once: the first tap turns the button into a red
    /// confirmation that reverts after a few seconds; a second tap within
    /// that window deletes.
    @State private var isConfirmingRemoval = false
    @State private var removalConfirmationTimeout: Task<Void, Never>?

    private static let edgePadding: CGFloat = 20

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
        VStack(spacing: 0) {
            Text("File Information")
                .font(.headline)
                .padding(.top, Self.edgePadding)
            form
            actionArea
                .padding(.horizontal, Self.edgePadding)
            HStack {
                Spacer()
                doneButton
            }
            .padding([.horizontal, .bottom], Self.edgePadding)
            .padding(.top, 16)
        }
        .frame(width: 380)
        .fixedSize(horizontal: false, vertical: true)
    }

    /// Closes the sheet, which the Mac cannot swipe away.
    private var doneButton: some View {
        Button("Done") {
            dismiss()
        }
        .keyboardShortcut(.cancelAction)
    }
    #else
    private var phoneBody: some View {
        NavigationStack {
            form
                .navigationTitle("File Information")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    Button("Done") {
                        dismiss()
                    }
                }
                .safeAreaInset(edge: .bottom) {
                    actionArea
                        .padding(.horizontal, Self.edgePadding)
                        .padding(.bottom, 8)
                }
        }
        .presentationDetents([.medium])
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
        if let kbps = book.bitrateKbps {
            detailRow(icon: bitrateIcon, label: Text("Bitrate")) {
                Text("\(kbps) kbps")
            }
        }
        if let bytes = book.fileSizeBytes {
            detailRow(icon: fileSizeIcon, label: Text("Size")) {
                Text(formatFileSize(bytes))
            }
        }
    }

    private func detailRow(icon: Icon, label: Text, @ViewBuilder value: () -> some View) -> some View {
        LabeledContent {
            value()
        } label: {
            Label {
                label
            } icon: {
                // Accented explicitly: the phone's form tints label icons
                // by itself, but the Mac's draws them plain.
                icon.accented
            }
        }
    }

    private var actionArea: some View {
        VStack(spacing: 12) {
            errorLine
            actionButton
        }
    }

    @ViewBuilder
    private var actionButton: some View {
        switch book.downloadState {
        case .notDownloaded:
            Button("Download") {
                book.download()
            }
            .buttonStyle(.borderedProminent)
            .disabled(!connection.isServerReachable)
        case .downloading(let progress):
            // An unknown fraction draws as an empty bar, never as the
            // indeterminate style: the Mac's linear bar keeps the
            // indeterminate bounce even after real fractions arrive.
            ProgressView(value: progress ?? 0)
                .progressViewStyle(.linear)
            Button("Cancel Download") {
                book.cancelDownload()
            }
            .buttonStyle(.borderedProminent)
            .tint(.red)
        case .downloaded:
            Button {
                handleRemovalTap()
            } label: {
                if isConfirmingRemoval {
                    Text("Confirm Removal")
                } else {
                    Text("Remove Download")
                }
            }
            .buttonStyle(.borderedProminent)
            .tint(.red)
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

    private func handleRemovalTap() {
        removalConfirmationTimeout?.cancel()
        guard isConfirmingRemoval else {
            isConfirmingRemoval = true
            removalConfirmationTimeout = Task { @MainActor in
                try? await Task.sleep(for: .seconds(4))
                guard !Task.isCancelled else { return }
                isConfirmingRemoval = false
            }
            return
        }
        isConfirmingRemoval = false
        book.removeDownload()
    }
}
