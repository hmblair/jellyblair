import SwiftUI

/// One book's screen. For the loaded book it is the playback screen with the
/// full controls; for any other book it is a preview whose Play button or
/// chapter tap switches playback here. Browsing previews never disturbs
/// whatever is playing.
public struct BookView: View {
    let book: Book

    @Environment(PlayerController.self) private var player
    @Environment(BookCatalog.self) private var catalog
    @Environment(ConnectionMonitor.self) private var connection
    @Environment(LibraryViewModel.self) private var library

    @Environment(\.openAuthor) private var openAuthor
    @Environment(\.openNarrator) private var openNarrator
    @Environment(\.openGenre) private var openGenre

    @State private var isShowingTranscript = false
    @State private var isHoveringDownload = false

    /// Measured height of the header's metadata column, which sizes the
    /// cover as a square of the same height.
    @State private var metadataHeight: CGFloat = 0

    /// Removal asks once: the first tap shows a red question mark that
    /// reverts after a few seconds; a second tap within that window deletes.
    @State private var isConfirmingRemoval = false
    @State private var removalConfirmationTimeout: Task<Void, Never>?

    public init(book: Book) {
        self.book = book
    }

    private var isLoaded: Bool {
        player.book?.id == book.id
    }

    private var model: BookModel {
        catalog.model(for: book)
    }

    private var chapters: [Chapter] {
        isLoaded ? player.chapters : model.chapters
    }

    /// Offline, only a downloaded book can start playing.
    private var canStartPlayback: Bool {
        connection.isServerReachable || model.downloadState == .downloaded
    }

    public var body: some View {
        // On the phone the list runs edge to edge; only the upper content
        // keeps side padding. The Mac pads the whole page. The loaded book's
        // controls live in the app-wide playback bar, not here.
        VStack(spacing: 16) {
            Group {
                header
                if !isLoaded {
                    playButton
                }
            }
            #if os(iOS)
            .padding(.horizontal, 20)
            #endif
            Divider()
            listSection
        }
        #if os(macOS)
        .padding(.horizontal, 20)
        .padding(.top, 20)
        #else
        .padding(.top, 8)
        #endif
        .toolbar {
            if hasTranscript {
                ToolbarItem(placement: .primaryAction) {
                    transcriptToggle
                }
            }
            ToolbarItem(placement: .primaryAction) {
                bookActionsMenu
            }
        }
    }

    /// Swaps the list below between the chapters and the transcript.
    /// The icon shows the view the button switches to.
    private var transcriptToggle: some View {
        Button {
            isShowingTranscript.toggle()
        } label: {
            Image(systemName: isShowingTranscript ? "list.bullet" : "text.quote")
        }
        .help(isShowingTranscript ? "Show the chapters" : "Show the transcript")
    }

    /// Actions on this book, in its title bar so it is clear which book
    /// they apply to.
    private var bookActionsMenu: some View {
        Menu {
            Button("Refresh Metadata") {
                refreshMetadata()
            }
            .disabled(!connection.isServerReachable)
            Button("Reset") {
                resetPlayback()
            }
            .disabled(!connection.isServerReachable)
        } label: {
            Image(systemName: "ellipsis.circle")
        }
        .menuIndicator(.hidden)
    }

    /// Re-reads everything the server and the file know about this book: the
    /// cover, the chapter list, the transcript, the resume position, and the
    /// library fields.
    private func refreshMetadata() {
        Task {
            await CoverImageLoader.shared.refresh(for: book.id, from: model.coverURL)
            if isLoaded {
                await player.refreshChapters()
                await player.refreshArtwork()
            } else {
                await model.refreshChapters()
            }
            await model.refreshLyrics()
            await model.refreshUserData()
            await library.load()
        }
    }

    /// Resets the book: the loaded book closes first, so playback stops,
    /// then the position returns to zero here and on the server.
    private func resetPlayback() {
        Task {
            if isLoaded {
                await player.close()
            }
            await model.resetPlayback()
        }
    }

    /// True while the transcript pane is the visible one. A transcript that
    /// disappears in a refresh falls back to the chapters, even though the
    /// toggle state remembers the choice.
    private var showsTranscriptPane: Bool {
        isShowingTranscript && hasTranscript
    }

    /// Both panes stay alive; the toolbar toggle changes only which one
    /// shows. The hidden transcript keeps tracking the narration, so
    /// switching to it opens on the current word without any repositioning.
    /// Each pane carries its own search bar and tracking button.
    private var listSection: some View {
        ZStack {
            ChapterListPane(
                book: book,
                model: model,
                chapters: chapters,
                marked: markedChapterIndex,
                isLoaded: isLoaded,
                canStartPlayback: canStartPlayback
            )
            .opacity(showsTranscriptPane ? 0 : 1)
            .allowsHitTesting(!showsTranscriptPane)
            if hasTranscript {
                TranscriptPane(
                    book: book,
                    model: model,
                    chapters: chapters,
                    isLoaded: isLoaded,
                    canStartPlayback: canStartPlayback,
                    isVisible: showsTranscriptPane
                )
                .opacity(showsTranscriptPane ? 1 : 0)
                .allowsHitTesting(showsTranscriptPane)
            }
        }
    }

    // MARK: - Header

    // The header layout is shared; only its measurements differ per platform.
    #if os(macOS)
    private static let coverCornerRadius: CGFloat = 10
    private static let coverSpacing: CGFloat = 12
    private static let titleFont = Font.title.bold()
    private static let lineFont = Font.title3
    #else
    private static let coverCornerRadius: CGFloat = 12
    private static let coverSpacing: CGFloat = 10
    private static let titleFont = Font.title2.bold()
    private static let lineFont = Font.callout
    #endif

    /// Centered title over a side-by-side section: cover at the left,
    /// left-aligned metadata lines beside it. The cover is a square with
    /// the metadata column's height, so the two sides always share one
    /// height.
    private var header: some View {
        VStack(spacing: 12) {
            Text(book.name)
                .font(Self.titleFont)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)

            // Two equal halves: the measured metadata column sizes the
            // cover, and each half claims its side of the center seam.
            HStack(alignment: .top, spacing: Self.coverSpacing) {
                cover
                    .frame(width: metadataHeight, height: metadataHeight)
                    .clipShape(RoundedRectangle(cornerRadius: Self.coverCornerRadius))
                    .frame(maxWidth: .infinity, alignment: .trailing)

                metadataColumn
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .onGeometryChange(for: CGFloat.self) { proxy in
                        proxy.size.height
                    } action: { height in
                        metadataHeight = height
                    }
            }
        }
        #if os(iOS)
        // The chapter list below competes for vertical space; without this the
        // stack compresses the text into truncation instead of wrapping it.
        .fixedSize(horizontal: false, vertical: true)
        #endif
    }

    private var metadataColumn: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !book.authors.isEmpty {
                metadataLine(icon: BookGroup.Kind.author.iconName) {
                    NameListLine(names: book.authors, open: openAuthor)
                }
            }
            if !book.narrators.isEmpty {
                metadataLine(icon: BookGroup.Kind.narrator.iconName) {
                    NameListLine(names: book.narrators, open: openNarrator)
                }
            }
            if let year = book.productionYear {
                metadataLine(icon: "calendar") { Text(verbatim: String(year)) }
            }
            if let genres = book.genres, !genres.isEmpty {
                metadataLine(icon: BookGroup.Kind.genre.iconName) {
                    NameListLine(names: genres, open: openGenre)
                }
            }
            metadataLine(icon: "clock.fill") { lengthLine }
            if let kbps = book.bitrateKbps {
                metadataLine(icon: "waveform") { Text("\(kbps) kbps") }
            }
            downloadRow
        }
        .font(Self.lineFont)
    }

    /// A metadata row: a small dimmed icon beside its text.
    private func metadataLine(icon: String, @ViewBuilder content: () -> some View) -> some View {
        metadataLine {
            Image(systemName: icon)
                .imageScale(.small)
        } content: {
            content()
        }
    }

    /// A metadata row with a custom view in the icon column. The content
    /// stays on one line and scrolls horizontally, but only when it
    /// overflows; a line that fits does not move.
    private func metadataLine(@ViewBuilder icon: () -> some View, @ViewBuilder content: () -> some View) -> some View {
        HStack(spacing: 6) {
            icon()
                .frame(width: 22)
            OverflowScrollLine {
                content()
            }
        }
    }

    private var cover: some View {
        BookCoverImage(bookID: book.id, url: catalog.coverURL(for: book), contentMode: .fit)
    }

    /// The book's total length.
    private var lengthLine: some View {
        Text(formatHoursMinutes(book.runTimeSeconds))
            .monospacedDigit()
    }

    /// The download control in the icon column with the file's size beside it.
    private var downloadRow: some View {
        metadataLine {
            downloadControl
                .imageScale(.small)
        } content: {
            if let bytes = book.fileSizeBytes {
                Text(formatFileSize(bytes))
            }
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
        model.removeDownload()
    }

    /// Download the book, cancel a download in progress, or show that the
    /// offline copy exists.
    @ViewBuilder
    private var downloadControl: some View {
        switch model.downloadState {
        case .notDownloaded:
            Button {
                model.download()
            } label: {
                Image(systemName: "arrow.down.circle.fill")
                    .foregroundStyle(.primary)
                    .opacity(isHoveringDownload ? 0.6 : 1)
                    .animation(.easeOut(duration: 0.1), value: isHoveringDownload)
            }
            .buttonStyle(.plain)
            .onHover { isHoveringDownload = $0 }
            .disabled(!connection.isServerReachable)
            .opacity(connection.isServerReachable ? 1 : 0.4)
        case .downloading(let progress):
            // The icon is the gauge: a faint vessel under a full-color copy
            // masked to the completed fraction. Tapping cancels.
            Button {
                model.cancelDownload()
            } label: {
                ZStack {
                    Image(systemName: "arrow.down.circle.fill")
                        .foregroundStyle(.quaternary)
                    Image(systemName: "arrow.down.circle.fill")
                        .foregroundStyle(.primary)
                        .mask {
                            GeometryReader { geometry in
                                Rectangle()
                                    .frame(height: geometry.size.height * (progress ?? 0))
                                    .frame(maxHeight: .infinity, alignment: .bottom)
                            }
                        }
                }
                .animation(.linear(duration: 0.3), value: progress)
                .opacity(isHoveringDownload ? 0.6 : 1)
                .animation(.easeOut(duration: 0.1), value: isHoveringDownload)
            }
            .buttonStyle(.plain)
            .onHover { isHoveringDownload = $0 }
        case .downloaded:
            Button {
                handleRemovalTap()
            } label: {
                Image(systemName: isConfirmingRemoval ? "questionmark.circle.fill" : "checkmark.circle.fill")
                    .foregroundStyle(isConfirmingRemoval ? Color.red : Color.green)
                    .contentTransition(.identity)
                    .animation(nil, value: isConfirmingRemoval)
                    .opacity(isHoveringDownload ? 0.6 : 1)
                    .animation(.easeOut(duration: 0.1), value: isHoveringDownload)
            }
            .buttonStyle(.plain)
            .onHover { isHoveringDownload = $0 }
        }
    }

    private var playButton: some View {
        Button {
            player.open(model, playWhenReady: true)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "play.fill")
                Text(model.resumePositionSeconds > 0 ? "Resume" : "Play")
                if let title = resumeChapterTitle {
                    Text(title)
                        .fontWeight(.light)
                        .lineLimit(1)
                }
            }
            .frame(minWidth: 100)
        }
        .buttonStyle(.borderedProminent)
        // The large control is a modest button on the Mac but a thick
        // capsule on the phone; the regular size matches the Mac's look.
        #if os(macOS)
        .controlSize(.large)
        #else
        .controlSize(.regular)
        #endif
        .disabled(!canStartPlayback)
    }

    /// The chapter the Resume button will land in, once chapters are known.
    private var resumeChapterTitle: String? {
        guard model.resumePositionSeconds > 0,
              let index = markedChapterIndex,
              chapters.indices.contains(index)
        else { return nil }
        return chapters[index].title
    }

    /// The chapter marked as current: the playing one when loaded,
    /// or the one containing the resume position in a preview.
    private var markedChapterIndex: Int? {
        if isLoaded {
            return player.currentChapterIndex
        }
        guard model.resumePositionSeconds > 0 else { return nil }
        return chapters.last(where: { $0.startSeconds <= model.resumePositionSeconds + Chapter.startSlackSeconds })?.index
    }

    /// True when this book can show a transcript: the server reports a lyric
    /// sidecar, or a fetched transcript is already cached.
    private var hasTranscript: Bool {
        book.hasLyrics == true || !model.lyrics.isEmpty
    }
}

/// Full width of an overflowing line's edge fade; a smaller overflow
/// shrinks the fade with it, so the fade dissolves as the edge approaches
/// the content's end instead of disappearing at full width.
private let overflowFadeWidth: CGFloat = 20

/// One line of content that scrolls horizontally only when it overflows.
/// Each clipped edge fades out while more content lies beyond it, so the
/// fade itself signals that the line can scroll; the fades follow the
/// scroll position and vanish at the content's true ends.
private struct OverflowScrollLine<Content: View>: View {
    @ViewBuilder let content: Content

    /// Points of content clipped beyond each edge.
    @State private var overflow = EdgeOverflow(leading: 0, trailing: 0)

    private struct EdgeOverflow: Equatable {
        var leading: CGFloat
        var trailing: CGFloat
    }

    var body: some View {
        ScrollView(.horizontal) {
            content
        }
        .scrollIndicators(.hidden)
        .scrollBounceBehavior(.basedOnSize, axes: [.horizontal])
        .onScrollGeometryChange(for: EdgeOverflow.self) { geometry in
            EdgeOverflow(
                leading: max(0, geometry.contentOffset.x),
                trailing: max(0, geometry.contentSize.width - geometry.containerSize.width - geometry.contentOffset.x)
            )
        } action: { _, newOverflow in
            overflow = newOverflow
        }
        .mask {
            fadeMask
        }
    }

    private var fadeMask: some View {
        HStack(spacing: 0) {
            LinearGradient(colors: [.clear, .black], startPoint: .leading, endPoint: .trailing)
                .frame(width: min(overflowFadeWidth, overflow.leading))
            Rectangle()
            LinearGradient(colors: [.black, .clear], startPoint: .leading, endPoint: .trailing)
                .frame(width: min(overflowFadeWidth, overflow.trailing))
        }
    }
}

/// A comma-separated list of names on one line, each name its own
/// click-and-hover target navigating to that name's books when the shell
/// provides a destination.
private struct NameListLine: View {
    let names: [String]
    let open: OpenBookGroupAction?

    @State private var hoveredName: String?

    var body: some View {
        HStack(spacing: 4) {
            ForEach(Array(names.enumerated()), id: \.offset) { index, name in
                item(name, isLast: index == names.count - 1)
            }
        }
    }

    /// The separating comma stays outside the name, so it takes no part in
    /// the hover effect.
    private func item(_ name: String, isLast: Bool) -> some View {
        HStack(spacing: 0) {
            nameView(name)
            if !isLast {
                Text(",")
            }
        }
    }

    @ViewBuilder
    private func nameView(_ name: String) -> some View {
        if let open {
            Button {
                open(name)
            } label: {
                Text(name)
                    .opacity(hoveredName == name ? 0.6 : 1)
                    .animation(.easeOut(duration: 0.1), value: hoveredName == name)
            }
            .buttonStyle(.plain)
            .onHover { hovering in
                if hovering {
                    hoveredName = name
                } else if hoveredName == name {
                    hoveredName = nil
                }
            }
        } else {
            Text(name)
        }
    }
}

/// Navigates to a group's books; injected per shell, since the sidebar
/// scopes on the Mac and the stack pushes on the phone.
public struct OpenBookGroupAction {
    private let handler: (String) -> Void

    public init(_ handler: @escaping (String) -> Void) {
        self.handler = handler
    }

    public func callAsFunction(_ authorName: String) {
        handler(authorName)
    }
}

/// Navigates to a book's screen; injected per shell.
public struct OpenBookAction {
    private let handler: (Book) -> Void

    public init(_ handler: @escaping (Book) -> Void) {
        self.handler = handler
    }

    public func callAsFunction(_ book: Book) {
        handler(book)
    }
}

public extension EnvironmentValues {
    @Entry var openAuthor: OpenBookGroupAction?
    @Entry var openNarrator: OpenBookGroupAction?
    @Entry var openGenre: OpenBookGroupAction?
    @Entry var openBook: OpenBookAction?
}
