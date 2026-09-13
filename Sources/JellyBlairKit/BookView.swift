import SwiftUI

/// What the book's screen remembers between visits. Stored on the book,
/// which lives for the session; the screen itself is torn down and rebuilt
/// with the book's identity.
public struct BookScreenState {
    public var isShowingTranscript = false

    public init() {}
}

/// One book's screen. For the loaded book it is the playback screen with the
/// full controls; for any other book it is a preview whose Play button or
/// chapter tap switches playback here. Browsing previews never disturbs
/// whatever is playing.
public struct BookView: View {
    let book: Book

    @Environment(PlayerController.self) private var player
    @Environment(ConnectionMonitor.self) private var connection

    @Environment(\.openBookGroup) private var openBookGroup

    @Environment(\.layoutMetrics) private var metrics

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

    private var chapters: [Chapter] {
        isLoaded ? player.chapters : book.chapters
    }

    /// Offline, only a downloaded book can start playing.
    private var canStartPlayback: Bool {
        connection.isServerReachable || book.isDownloaded
    }

    public var body: some View {
        // When compact the list runs edge to edge and only the upper content
        // keeps side padding; a regular page pads as a whole. The loaded
        // book's controls live in the app-wide playback bar, not here.
        VStack(spacing: 16) {
            Group {
                header
                if !isLoaded {
                    playButton
                }
            }
            .padding(.horizontal, metrics.bookScreen.contentHorizontalPadding)
            listSection
        }
        .padding(.horizontal, metrics.bookScreen.pageHorizontalPadding)
        .padding(.top, metrics.bookScreen.pageTopPadding)
        .padding(.bottom, metrics.bookScreen.pageBottomPadding)
        // The cover, blurred into a wash behind the page, is what the glass
        // cards pick up, so each book colors its own screen. The extension
        // effect carries the wash into the adjacent safe areas, under the
        // title bar and the floating sidebar, whose glass continues it.
        .background(alignment: .top) {
            coverBackdrop
                .backgroundExtensionEffect()
        }
        .toolbar {
            #if os(macOS)
            // The hidden-title window packs items at the leading edge; the
            // spacer pushes them back to the trailing one.
            ToolbarSpacer(.flexible)
            #endif
            if hasTranscript {
                ToolbarItem(placement: .primaryAction) {
                    transcriptToggle
                }
            }
            ToolbarItem(placement: .primaryAction) {
                bookActionsMenu
            }
            // Last, so the settings button keeps the same place on every screen.
            ToolbarItem(placement: .primaryAction) {
                SettingsToolbarButton()
            }
        }
    }

    /// Swaps the list below between the chapters and the transcript.
    /// The icon shows the view the button switches to.
    private var transcriptToggle: some View {
        Button {
            book.screenState.isShowingTranscript.toggle()
        } label: {
            Image(systemName: book.screenState.isShowingTranscript ? "list.bullet" : "text.quote")
        }
        .help(book.screenState.isShowingTranscript ? "Show the chapters" : "Show the transcript")
    }

    /// Actions on this book, in its title bar so it is clear which book
    /// they apply to.
    private var bookActionsMenu: some View {
        Menu {
            BookActionsMenuItems(book: book)
        } label: {
            Image(systemName: "ellipsis.circle.fill")
        }
        .menuIndicator(.hidden)
    }

    /// True while the transcript pane is the visible one. A transcript that
    /// disappears in a refresh falls back to the chapters, even though the
    /// toggle state remembers the choice.
    private var showsTranscriptPane: Bool {
        book.screenState.isShowingTranscript && hasTranscript
    }

    #if os(macOS)
    /// The chapter/transcript pane's height floor. With the header's
    /// intrinsic height above it, it sets the Mac window's minimum
    /// height, which no other platform has.
    private static let listMinHeight: CGFloat = 180
    #endif

    /// Both panes stay alive; the toolbar toggle changes only which one
    /// shows. The hidden transcript sleeps and catches up in one step when
    /// shown, so switching to it still opens on the current word.
    /// Each pane carries its own search bar and tracking button.
    private var listSection: some View {
        ZStack {
            ChapterListPane(
                book: book,
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
                    chapters: chapters,
                    isLoaded: isLoaded,
                    canStartPlayback: canStartPlayback,
                    isVisible: showsTranscriptPane
                )
                .opacity(showsTranscriptPane ? 1 : 0)
                .allowsHitTesting(showsTranscriptPane)
            }
        }
        #if os(macOS)
        .frame(minHeight: Self.listMinHeight)
        #endif
        .paneBackdrop(metrics.pane.backdrop)
        // The inner cap keeps the rows readable; the outer frame centers
        // the card in the width the cap leaves over.
        .frame(maxWidth: metrics.pane.maxWidth)
        .frame(maxWidth: .infinity)
    }

    // MARK: - Header

    /// The height of the cover wash, fading to nothing before the page's
    /// lower half.
    private static let backdropHeight: CGFloat = 480

    /// The book's cover as an ambient wash behind the page.
    private var coverBackdrop: some View {
        BookCoverImage(bookID: book.id, url: book.coverURL, contentMode: .fill)
            .frame(maxWidth: .infinity)
            .frame(height: Self.backdropHeight)
            .clipped()
            .blur(radius: 60)
            .opacity(0.35)
            .mask(LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom))
            .allowsHitTesting(false)
    }

    /// Centered title over a side-by-side section: cover at the left,
    /// left-aligned metadata lines beside it. The cover is a square with
    /// the metadata column's height, so the two sides always share one
    /// height.
    private var header: some View {
        VStack(spacing: 12) {
            Text(book.name)
                .font(metrics.bookScreen.titleFont)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)

            // Two equal halves: the measured metadata column sizes the
            // cover, and each half claims its side of the center seam.
            HStack(alignment: .top, spacing: metrics.bookScreen.coverSpacing) {
                cover
                    .frame(width: metadataHeight, height: metadataHeight)
                    .clipShape(RoundedRectangle(cornerRadius: metrics.bookScreen.coverCornerRadius))
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
        .fixedSize(horizontal: false, vertical: metrics.bookScreen.headerKeepsIntrinsicHeight)
    }

    private var metadataColumn: some View {
        VStack(alignment: .leading, spacing: 6) {
            groupLine(.author)
            groupLine(.narrator)
            groupLine(.publisher)
            if let year = book.productionYear {
                metadataLine(icon: yearIconName) { Text(verbatim: String(year)) }
            }
            groupLine(.genre)
            metadataLine(icon: durationIconName) { lengthLine }
            if let kbps = book.bitrateKbps {
                metadataLine(icon: "waveform") { Text("\(kbps) kbps") }
            }
            downloadRow
        }
        .font(metrics.bookScreen.lineFont)
    }

    /// A metadata row for one grouping kind, with each name navigating to
    /// that name's books. The row disappears when the book has no names of
    /// the kind.
    @ViewBuilder
    private func groupLine(_ kind: BookGroup.Kind) -> some View {
        let names = kind.names(of: book)
        if !names.isEmpty {
            metadataLine(icon: kind.iconName) {
                NameListLine(kind: kind, names: names, open: openBookGroup)
            }
        }
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
        BookCoverImage(bookID: book.id, url: book.coverURL, contentMode: .fit)
    }

    /// The book's total length.
    private var lengthLine: some View {
        Text(formatHoursMinutes(book.runTimeSeconds))
            .monospacedDigit()
    }

    /// The download control in the icon column, with the file's size beside
    /// it, or the last failure until a retry starts.
    private var downloadRow: some View {
        metadataLine {
            downloadControl
                .imageScale(.small)
        } content: {
            if let message = book.downloadErrorMessage {
                Text(message)
                    .foregroundStyle(.red)
            } else if let bytes = book.fileSizeBytes {
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
        book.removeDownload()
    }

    /// Download the book, cancel a download in progress, or show that the
    /// offline copy exists.
    @ViewBuilder
    private var downloadControl: some View {
        switch book.downloadState {
        case .notDownloaded:
            Button {
                book.download()
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
                book.cancelDownload()
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
            player.open(book, playWhenReady: true)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "play.fill")
                Text(book.isInProgress ? "Resume" : "Play")
                if let title = resumeChapterTitle {
                    Text(title)
                        .fontWeight(.light)
                        .lineLimit(1)
                }
            }
            .frame(minWidth: 100)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(metrics.bookScreen.playButtonControlSize)
        .disabled(!canStartPlayback)
    }

    /// The chapter the Resume button will land in, once chapters are known.
    private var resumeChapterTitle: String? {
        guard book.isInProgress,
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
        guard book.isInProgress else { return nil }
        return chapters.last(where: { $0.startSeconds <= book.resumePositionSeconds + Chapter.startSlackSeconds })?.index
    }

    /// True when this book can show a transcript: the server reports a lyric
    /// sidecar, or a fetched transcript is already cached.
    private var hasTranscript: Bool {
        book.hasLyrics == true || !book.lyrics.isEmpty
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
    let kind: BookGroup.Kind
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
                open(kind, name)
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

/// Navigates to a group's books; injected per shell, since a regular
/// layout scopes its list in place and a compact one pushes a screen.
public struct OpenBookGroupAction {
    private let handler: (BookGroup.Kind, String) -> Void

    public init(_ handler: @escaping (BookGroup.Kind, String) -> Void) {
        self.handler = handler
    }

    public func callAsFunction(_ kind: BookGroup.Kind, _ name: String) {
        handler(kind, name)
    }
}

public extension EnvironmentValues {
    @Entry var openBookGroup: OpenBookGroupAction?
}

/// The actions on one book, shared by the book screen's title-bar menu and
/// the library rows' context menus.
public struct BookActionsMenuItems: View {
    let book: Book

    @Environment(PlayerController.self) private var player
    @Environment(ConnectionMonitor.self) private var connection

    public init(book: Book) {
        self.book = book
    }

    private var isLoaded: Bool {
        player.book?.id == book.id
    }

    public var body: some View {
        Button("Refresh Metadata") {
            refreshMetadata()
        }
        .disabled(!connection.isServerReachable)
        Button("Reset Playback") {
            resetPlayback()
        }
        .disabled(!connection.isServerReachable || !book.isInProgress)
    }

    /// Re-reads everything the server and the file know about this book: the
    /// cover, the chapter list, the transcript, and the record with its
    /// resume position.
    private func refreshMetadata() {
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
    private func resetPlayback() {
        Task {
            if isLoaded {
                await player.close()
            }
            await book.resetPlayback()
        }
    }
}
