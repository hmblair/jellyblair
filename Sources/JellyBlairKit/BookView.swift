import SwiftUI

/// One book's screen. For the loaded book it is the playback screen with the
/// full controls; for any other book it is a preview whose Play button or
/// chapter tap switches playback here. Browsing previews never disturbs
/// whatever is playing.
public struct BookView: View {
    let book: Book

    @Environment(PlayerController.self) private var player
    @Environment(BookCatalog.self) private var catalog

    @State private var isAutoScrollWindowOpen = true

    /// The book with fresh user data from the server. The library snapshot's
    /// resume position can be stale, which would mislabel the play button
    /// and misplace the progress marks.
    @State private var refreshedBook: Book?

    public init(book: Book) {
        self.book = book
    }

    private var isLoaded: Bool {
        player.book?.id == book.id
    }

    private var displayBook: Book {
        refreshedBook ?? book
    }

    private var chapters: [Chapter] {
        isLoaded ? player.chapters : catalog.cachedChapters(for: book)
    }

    public var body: some View {
        VStack(spacing: 16) {
            header
            if isLoaded {
                if let message = player.playbackErrorMessage {
                    errorBanner(message)
                }
                SeekBarView()
                TransportControlsView()
            } else {
                playButton
            }
            Divider()
            chapterList
        }
        .padding(20)
    }

    // MARK: - Header

    #if os(macOS)
    private static let coverSize: CGFloat = 175

    /// Side-by-side header: cover at the left, text beside it.
    private var header: some View {
        HStack(alignment: .top, spacing: 16) {
            cover
                .frame(width: Self.coverSize, height: Self.coverSize)
                .clipShape(RoundedRectangle(cornerRadius: 10))

            VStack(alignment: .leading, spacing: 6) {
                Text(book.name)
                    .font(.title2.bold())
                Text(book.authorAndRuntimeText)
                if let narrator = book.narrator {
                    Text("Narrated by \(narrator)")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                positionLine
            }
            Spacer()
        }
        .frame(height: Self.coverSize)
    }
    #else
    private static let coverSize: CGFloat = 220

    /// Stacked header for the narrow screen: large centered cover, then text
    /// that wraps freely.
    private var header: some View {
        VStack(spacing: 6) {
            cover
                .frame(width: Self.coverSize, height: Self.coverSize)
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .padding(.bottom, 6)

            Text(book.name)
                .font(.title3.bold())
                .multilineTextAlignment(.center)
            Text(book.authorAndRuntimeText)
                .font(.subheadline)
                .multilineTextAlignment(.center)
            if let narrator = book.narrator {
                Text("Narrated by \(narrator)")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            positionLine
        }
        .frame(maxWidth: .infinity)
    }
    #endif

    private var cover: some View {
        BookCoverImage(bookID: book.id, url: catalog.coverURL(for: book), contentMode: .fit)
    }

    @ViewBuilder
    private var positionLine: some View {
        if isLoaded {
            RemainingTimeView()
        } else if displayBook.resumePositionSeconds > 0 {
            Text("\(formatTime(displayBook.resumePositionSeconds)) in")
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
        }
    }

    private func errorBanner(_ message: String) -> some View {
        HStack {
            Label(message, systemImage: "exclamationmark.triangle")
                .foregroundStyle(.red)
            Spacer()
            Button("Retry") {
                player.retryCurrentBook()
            }
        }
    }

    private var playButton: some View {
        Button {
            player.open(book, playWhenReady: true)
        } label: {
            Label(displayBook.resumePositionSeconds > 0 ? "Resume" : "Play", systemImage: "play.fill")
                .frame(minWidth: 100)
        }
        .controlSize(.large)
    }

    // MARK: - Chapters

    private var chapterList: some View {
        ScrollViewReader { proxy in
            List(chapters) { chapter in
                ChapterRow(
                    chapter: chapter,
                    state: rowState(for: chapter),
                    meter: player.audioMeter
                )
                .contentShape(Rectangle())
                .onTapGesture {
                    if isLoaded {
                        Task { await player.jump(to: chapter) }
                    } else {
                        player.open(book, playWhenReady: true, startAtSeconds: chapter.startSeconds)
                    }
                }
            }
            .listStyle(.inset)
            .overlay {
                if chapters.isEmpty {
                    if catalog.isFetchingChapters(for: book) {
                        ProgressView()
                    } else {
                        Text("No chapters in this file")
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .onAppear {
                scrollToMarkedChapter(proxy)
            }
            .onChange(of: chapters) {
                scrollToMarkedChapter(proxy)
            }
            .onChange(of: refreshedBook) {
                scrollToMarkedChapter(proxy)
            }
            .onChange(of: player.currentChapterIndex) {
                guard isLoaded, isAutoScrollWindowOpen else { return }
                scrollToMarkedChapter(proxy)
            }
            .task {
                try? await Task.sleep(for: .seconds(3))
                isAutoScrollWindowOpen = false
            }
            .task(id: book.id) {
                guard !isLoaded else { return }
                async let freshFetch = catalog.freshBook(book)
                await catalog.fetchChapters(for: book)
                if let fresh = await freshFetch {
                    refreshedBook = fresh
                }
            }
        }
    }

    /// The chapter marked as current: the playing one when loaded,
    /// or the one containing the resume position in a preview.
    private var markedChapterIndex: Int? {
        if isLoaded {
            return player.currentChapterIndex
        }
        guard displayBook.resumePositionSeconds > 0 else { return nil }
        return chapters.last(where: { $0.startSeconds <= displayBook.resumePositionSeconds + 0.5 })?.index
    }

    /// Centers the list on the marked chapter shortly after opening,
    /// then disarms so playback does not move a list being browsed.
    private func scrollToMarkedChapter(_ proxy: ScrollViewProxy) {
        guard let index = markedChapterIndex else { return }
        proxy.scrollTo(index, anchor: .center)
    }

    /// Played and upcoming are positional relative to the marked chapter,
    /// so the list mirrors the book's progress.
    private func rowState(for chapter: Chapter) -> ChapterRowState {
        guard let marked = markedChapterIndex else { return .upcoming }
        if chapter.index < marked { return .played }
        if chapter.index > marked { return .upcoming }
        guard isLoaded else { return .current(.bookmark) }
        return .current(player.isPlaying ? .playing : .paused)
    }
}
