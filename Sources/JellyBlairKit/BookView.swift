import SwiftUI

/// What the book's screen remembers between visits. Stored on the book,
/// which lives for the session; the screen itself is torn down and rebuilt
/// with the book's identity.
public struct BookScreenState {
    public var isShowingTranscript = false

    public init() {}
}

/// One book's screen, composed from the header components. When compact it
/// is the playback screen: the cover and title block over the loaded
/// book's live transport, or over the play button for any other book, with
/// the chapters and the transcript as sheets. When regular it is a detail
/// page — the title block beside the cover, with the play button for a
/// book not loaded — over the inline panes, leaving the transport to the
/// playback bar. A play button or chapter tap switches playback here;
/// browsing never disturbs whatever is playing.
public struct BookView: View {
    let book: Book

    @Environment(PlayerController.self) private var player
    @Environment(ConnectionMonitor.self) private var connection

    @Environment(\.layoutDensity) private var density
    @Environment(\.layoutMetrics) private var metrics

    @State private var isShowingDetails = false

    /// Measured height of the regular play button, which hangs under the
    /// title block by its own height; see regularHeader.
    @State private var playButtonHeight: CGFloat = 0

    /// The compact screen's pane sheets.
    @State private var isShowingChapterSheet = false
    @State private var isShowingTranscriptSheet = false

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
        VStack(spacing: 16) {
            if density == .compact {
                compactPlayer
            } else {
                regularHeader
                listSection
            }
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
            ToolbarItem(placement: .primaryAction) {
                detailsButton
            }
            if density == .regular, hasTranscript {
                ToolbarItem(placement: .primaryAction) {
                    transcriptToggle
                }
            }
            // Last, so the settings button keeps the same place on every screen.
            ToolbarItem(placement: .primaryAction) {
                SettingsToolbarButton()
            }
        }
        .sheet(isPresented: $isShowingDetails) {
            BookDetailsSheet(book: book)
        }
        .sheet(isPresented: $isShowingChapterSheet) {
            PhoneSheet(title: Text("Chapters")) {
                chapterPane
                    .paneBackdrop(metrics.pane.backdrop)
            }
        }
        .sheet(isPresented: $isShowingTranscriptSheet) {
            PhoneSheet(title: Text("Transcript")) {
                transcriptPane(isVisible: true)
                    .paneBackdrop(metrics.pane.backdrop)
            }
        }
    }

    // MARK: - Compact player

    /// The playback screen filling the compact page: the centered column
    /// between the spacers, with the pane buttons at the bottom.
    @ViewBuilder
    private var compactPlayer: some View {
        Spacer(minLength: 0)
        VStack(spacing: 0) {
            BookPlayerCover(book: book)
            BookTitleBlock(book: book, alignment: .center)
                .padding(.top, 20)
            playbackSection
                .padding(.top, 24)
        }
        .padding(.horizontal, metrics.bookScreen.contentHorizontalPadding)
        Spacer(minLength: 0)
        paneButtons
    }

    /// The loaded book's live transport, or the play button with its
    /// caption for any other book, whose bottom bar has the transport.
    @ViewBuilder
    private var playbackSection: some View {
        if isLoaded {
            BookTransport()
        } else {
            VStack(spacing: 10) {
                BookPlayButton(book: book, canStart: canStartPlayback)
                BookPlaybackCaption(book: book)
            }
        }
    }

    /// Opens the chapter and transcript sheets, standing in for the panes
    /// the compact screen has no room for.
    private var paneButtons: some View {
        HStack(spacing: 44) {
            if !chapters.isEmpty {
                Button {
                    isShowingChapterSheet = true
                } label: {
                    Image(systemName: "list.bullet")
                }
                .help("Show the chapters")
            }
            if hasTranscript {
                Button {
                    isShowingTranscriptSheet = true
                } label: {
                    Image(systemName: "text.quote")
                }
                .help("Show the transcript")
            }
        }
        .font(.system(size: 18))
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
    }

    // MARK: - Regular header

    /// The detail header: the title block and the play button beside the
    /// cover, sharing the pane's width so the edges line up. The bottom
    /// bar carries the chapter and time readouts, so the page repeats
    /// neither, and while this book is loaded the button leaves too —
    /// playback is the bar's to control.
    private var regularHeader: some View {
        HStack(spacing: 24) {
            BookPlayerCover(book: book)
            BookTitleBlock(book: book, alignment: .leading)
                // The button hangs below the block without joining the
                // layout, so the text keeps its centering against the
                // cover and nothing moves when the button leaves on load.
                // The measured height shifts it fully past the block's
                // bottom edge.
                .overlay(alignment: .bottomLeading) {
                    if !isLoaded {
                        BookPlayButton(book: book, canStart: canStartPlayback)
                            .onGeometryChange(for: CGFloat.self) { proxy in
                                proxy.size.height
                            } action: { height in
                                playButtonHeight = height
                            }
                            .offset(y: playButtonHeight + 16)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: metrics.pane.maxWidth)
        .frame(maxWidth: .infinity)
    }

    // MARK: - Panes

    /// Swaps the list below between the chapters and the transcript.
    /// The icon shows the view the button switches to.
    private var transcriptToggle: some View {
        Button {
            book.screenState.isShowingTranscript.toggle()
        } label: {
            Image(systemName: book.screenState.isShowingTranscript ? "list.bullet" : "text.quote")
        }
        .help(book.screenState.isShowingTranscript ? Text("Show the chapters") : Text("Show the transcript"))
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
            chapterPane
                .opacity(showsTranscriptPane ? 0 : 1)
                .allowsHitTesting(!showsTranscriptPane)
            if hasTranscript {
                transcriptPane(isVisible: showsTranscriptPane)
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

    /// The chapter pane on this book, shared by the regular list section
    /// and the compact sheet.
    private var chapterPane: some View {
        ChapterListPane(
            book: book,
            chapters: chapters,
            marked: markedChapterIndex,
            isLoaded: isLoaded,
            canStartPlayback: canStartPlayback
        )
    }

    /// The transcript pane on this book, shared by the regular list
    /// section and the compact sheet.
    private func transcriptPane(isVisible: Bool) -> some View {
        TranscriptPane(
            book: book,
            chapters: chapters,
            isLoaded: isLoaded,
            canStartPlayback: canStartPlayback,
            isVisible: isVisible
        )
    }

    // MARK: - Shared

    private var detailsButton: some View {
        Button {
            isShowingDetails = true
        } label: {
            Image(systemName: "info.circle.fill")
        }
        .help("Show the book's details")
    }

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

    /// The chapter marked as current: the playing one when loaded,
    /// or the one containing the resume position in a preview.
    private var markedChapterIndex: Int? {
        if isLoaded {
            return player.currentChapterIndex
        }
        guard book.isStarted else { return nil }
        return book.resumeChapter?.index
    }

    /// True when this book can show a transcript: the server reports a lyric
    /// sidecar, or a fetched transcript is already cached.
    private var hasTranscript: Bool {
        book.hasLyrics == true || !book.lyrics.isEmpty
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
