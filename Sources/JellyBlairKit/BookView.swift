import SwiftUI

/// One book's screen. For the loaded book it is the playback screen with the
/// full controls; for any other book it is a preview whose Play button or
/// chapter tap switches playback here. Browsing previews never disturbs
/// whatever is playing.
public struct BookView: View {
    let book: Book

    @Environment(PlayerController.self) private var player
    @Environment(BookCatalog.self) private var catalog

    @Environment(\.scenePhase) private var scenePhase

    @State private var isAutoScrollWindowOpen = true
    @State private var chapterQuery = ""

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

    /// Chapters whose titles contain the query; all of them when it is empty.
    /// Filtering only subsets the rows, so progress marks stay truthful.
    private var visibleChapters: [Chapter] {
        let trimmed = chapterQuery.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return chapters }
        return chapters.filter { $0.title.localizedCaseInsensitiveContains(trimmed) }
    }

    public var body: some View {
        // On the phone the list runs edge to edge; only the upper content
        // keeps side padding. The Mac pads the whole page.
        VStack(spacing: 16) {
            Group {
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
            }
            #if os(iOS)
            .padding(.horizontal, 20)
            #endif
            Divider()
            chapterFilterField
            chapterList
        }
        #if os(macOS)
        .padding(20)
        #else
        .padding(.top, 8)
        #endif
    }

    /// A slim filter row attached to the top of the chapter list.
    private var chapterFilterField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.callout)
                .foregroundStyle(.secondary)
            TextField("Search Chapters", text: $chapterQuery)
                .textFieldStyle(.plain)
                .autocorrectionDisabled()
            if !chapterQuery.isEmpty {
                Button {
                    chapterQuery = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.vertical, 5)
        .padding(.horizontal, 8)
        .background(
            Capsule()
                .fill(Color.primary.opacity(0.06))
        )
        #if os(iOS)
        .padding(.horizontal, 20)
        #endif
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
                if let author = book.author {
                    Text(author)
                }
                if let narrator = book.narrator {
                    Text("Narrated by \(narrator)")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                lengthLine
                Spacer()
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
            if let author = book.author {
                Text(author)
                    .font(.subheadline)
                    .multilineTextAlignment(.center)
            }
            if let narrator = book.narrator {
                Text("Narrated by \(narrator)")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            lengthLine
        }
        .frame(maxWidth: .infinity)
        // The chapter list below competes for vertical space; without this the
        // stack compresses the text into truncation instead of wrapping it.
        .fixedSize(horizontal: false, vertical: true)
    }
    #endif

    private var cover: some View {
        BookCoverImage(bookID: book.id, url: catalog.coverURL(for: book), contentMode: .fit)
    }

    /// "Total Length · Remaining", the remaining part gray and only shown
    /// when the book is partway through.
    private var lengthLine: some View {
        HStack(spacing: 5) {
            Text(formatHoursMinutes(book.runTimeSeconds))
            if isLoaded {
                Text("·")
                    .foregroundStyle(.secondary)
                RemainingTimeView()
            } else if model.resumePositionSeconds > 0 {
                Text("· \(formatHoursMinutes(book.runTimeSeconds - model.resumePositionSeconds)) remaining")
                    .foregroundStyle(.secondary)
            }
        }
        .font(.callout.monospacedDigit())
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
        .controlSize(.large)
    }

    /// The chapter the Resume button will land in, once chapters are known.
    private var resumeChapterTitle: String? {
        guard model.resumePositionSeconds > 0,
              let index = markedChapterIndex,
              chapters.indices.contains(index)
        else { return nil }
        return chapters[index].title
    }

    // MARK: - Chapters

    private var chapterList: some View {
        ScrollViewReader { proxy in
            List(visibleChapters) { chapter in
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
                        player.open(model, playWhenReady: true, startAtSeconds: chapter.startSeconds)
                    }
                }
            }
            .platformChapterListStyle()
            .overlay {
                if chapters.isEmpty {
                    if model.isFetchingChapters {
                        ProgressView()
                    } else {
                        Text("No chapters in this file")
                            .foregroundStyle(.secondary)
                    }
                } else if visibleChapters.isEmpty {
                    ContentUnavailableView.search(text: chapterQuery)
                }
            }
            .onAppear {
                scrollToMarkedChapter(proxy)
            }
            .onChange(of: chapters) {
                scrollToMarkedChapter(proxy)
            }
            .onChange(of: model.resumePositionSeconds) {
                guard !isLoaded else { return }
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
                async let userDataFetch: Void = model.refreshUserData()
                await model.fetchChaptersIfNeeded()
                await model.prewarmAsset()
                await userDataFetch
            }
            .onChange(of: scenePhase) { _, phase in
                // Coming back to a book that is not playing can be much later:
                // the position may have moved on another device.
                guard phase == .active, !isLoaded else { return }
                Task { await model.refreshUserData() }
            }
        }
    }

    /// The chapter marked as current: the playing one when loaded,
    /// or the one containing the resume position in a preview.
    private var markedChapterIndex: Int? {
        if isLoaded {
            return player.currentChapterIndex
        }
        guard model.resumePositionSeconds > 0 else { return nil }
        return chapters.last(where: { $0.startSeconds <= model.resumePositionSeconds + 0.5 })?.index
    }

    /// Centers the list on the marked chapter shortly after opening,
    /// then disarms so playback does not move a list being browsed.
    private func scrollToMarkedChapter(_ proxy: ScrollViewProxy) {
        guard let index = markedChapterIndex,
              visibleChapters.contains(where: { $0.index == index })
        else { return }
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

private extension View {
    /// Edge-to-edge rows on the phone; the inset style on the Mac.
    func platformChapterListStyle() -> some View {
        #if os(iOS)
        return listStyle(.plain)
        #else
        return listStyle(.inset)
        #endif
    }
}
