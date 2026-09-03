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

    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.openAuthor) private var openAuthor
    @Environment(\.openNarrator) private var openNarrator
    @Environment(\.openGenre) private var openGenre

    @State private var filterQuery = ""
    @State private var isShowingTranscript = false
    /// The spoken word's last reported height in the transcript content,
    /// for scrolling only when the narration moves to a new wrapped row.
    @State private var trackedWordY: CGFloat?
    @State private var isHoveringJumpButton = false
    @State private var isHoveringTranscriptToggle = false
    @State private var isHoveringDownload = false

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

    /// Chapters whose titles contain the query; all of them when it is empty.
    /// Filtering only subsets the rows, so progress marks stay truthful.
    private var visibleChapters: [Chapter] {
        let trimmed = filterQuery.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return chapters }
        return chapters.filter { $0.title.localizedCaseInsensitiveContains(trimmed) }
    }

    /// Transcript lines whose text contains the query; all of them when it is empty.
    private var visibleLines: [LyricLine] {
        let trimmed = filterQuery.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return model.lyrics }
        return model.lyrics.filter { $0.text.localizedCaseInsensitiveContains(trimmed) }
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
            listSection
                .modifier(ExtendToScreenBottom())
        }
        #if os(macOS)
        .padding(.horizontal, 20)
        .padding(.top, 20)
        #else
        .padding(.top, 8)
        #endif
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                bookActionsMenu
            }
        }
    }

    /// Actions on this book, in its title bar so it is clear which book
    /// they apply to.
    private var bookActionsMenu: some View {
        Menu {
            Button("Refresh Metadata") {
                refreshMetadata()
            }
            .disabled(!connection.isServerReachable)
        } label: {
            Image(systemName: "ellipsis.circle")
        }
        .menuIndicator(.hidden)
    }

    /// Re-reads everything the server and the file know about this book: the
    /// chapter list, the transcript, the resume position, and the library fields.
    private func refreshMetadata() {
        Task {
            if isLoaded {
                await player.refreshChapters()
            } else {
                await model.refreshChapters()
            }
            await model.refreshLyrics()
            await model.refreshUserData()
            await library.load()
        }
    }

    /// The filter bar floats over the list, whose rows scroll up behind it,
    /// masked to nothing in the bar's zone with a fade beneath.
    private var listSection: some View {
        ScrollViewReader { proxy in
            ZStack(alignment: .top) {
                Group {
                    if isShowingTranscript {
                        transcriptList(proxy)
                    } else {
                        chapterList(proxy)
                    }
                }
                .fadedUnderFloatingBar(fadesBottom: true)
                HStack(spacing: 8) {
                    filterField
                    if hasTranscript {
                        transcriptToggle
                    }
                    trackingButton(proxy)
                }
                #if os(iOS)
                .padding(.horizontal, 20)
                #endif
            }
        }
    }

    /// Toggles tracking, which is on by default and shared across books.
    /// Turning it on clears any filter that hides the position and centers
    /// it right away. Scrolling the list by hand turns tracking off.
    private func trackingButton(_ proxy: ScrollViewProxy) -> some View {
        Button {
            player.isTrackingPosition.toggle()
            guard player.isTrackingPosition else { return }
            filterQuery = ""
            Task { @MainActor in
                centerOnTrackedPosition(proxy)
            }
        } label: {
            Image(systemName: "scope")
                .font(.callout)
                .foregroundStyle(player.isTrackingPosition ? Color.white : Color.secondary)
                .padding(.vertical, 5)
                .padding(.horizontal, 8)
                .background(
                    Capsule()
                        .fill(player.isTrackingPosition ? Color.accentColor : Color.primary.opacity(isHoveringJumpButton ? 0.12 : 0.06))
                        .animation(.easeOut(duration: 0.1), value: isHoveringJumpButton)
                )
        }
        .buttonStyle(.plain)
        .onHover { isHoveringJumpButton = $0 }
        .help(player.isTrackingPosition ? "Stop following the listening position" : "Follow the listening position")
        .disabled(jumpTargetIndex == nil)
        .opacity(jumpTargetIndex == nil ? 0.4 : 1)
    }

    /// Centers the listener's position while tracking is on. Every centering
    /// goes through here: opening a book, pressing the tracking button, and
    /// the marked chapter moving. The unanimated form serves openings, where
    /// an animated scroll would glide across the whole list.
    private func centerOnTrackedPosition(_ proxy: ScrollViewProxy, animated: Bool = true) {
        guard player.isTrackingPosition else { return }
        if animated {
            withAnimation { scrollToCurrentPosition(proxy) }
        } else {
            scrollToCurrentPosition(proxy)
        }
    }

    /// The row tracking centers on, in whichever list is showing.
    private var jumpTargetIndex: Int? {
        isShowingTranscript ? currentLineIndex(at: Date()) : markedChapterIndex
    }

    private func scrollToCurrentPosition(_ proxy: ScrollViewProxy) {
        if isShowingTranscript {
            scrollToSpokenWord(proxy)
        } else {
            scrollToMarkedChapter(proxy)
        }
    }

    /// Swaps the list below between the chapters and the transcript.
    /// The icon shows the view the button switches to.
    private var transcriptToggle: some View {
        Button {
            filterQuery = ""
            isShowingTranscript.toggle()
        } label: {
            Image(systemName: isShowingTranscript ? "list.bullet" : "text.quote")
                .font(.callout)
                .foregroundStyle(.secondary)
                .padding(.vertical, 5)
                .padding(.horizontal, 8)
                .background(
                    Capsule()
                        .fill(Color.primary.opacity(isHoveringTranscriptToggle ? 0.12 : 0.06))
                        .animation(.easeOut(duration: 0.1), value: isHoveringTranscriptToggle)
                )
        }
        .buttonStyle(.plain)
        .onHover { isHoveringTranscriptToggle = $0 }
        .help(isShowingTranscript ? "Show the chapters" : "Show the transcript")
    }

    private var filterField: some View {
        CapsuleSearchField(isShowingTranscript ? "Search Transcript" : "Search Chapters", text: $filterQuery)
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
    /// left-aligned metadata lines beside it. The height follows the text,
    /// which can outgrow the cover.
    private var header: some View {
        VStack(spacing: 12) {
            Text(book.name)
                .font(Self.titleFont)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)

            // Two equal halves: the cover fills its half as a square, the
            // metadata lines take the other.
            HStack(alignment: .top, spacing: Self.coverSpacing) {
                // The square fits its half's width and the header's height,
                // whichever is tighter. The clip hugs the image itself; the
                // outer frame then claims the half, with the cover against
                // the metadata beside it.
                cover
                    .aspectRatio(1, contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: Self.coverCornerRadius))
                    .frame(maxWidth: .infinity, alignment: .trailing)

                VStack(alignment: .leading, spacing: 6) {
                    if let author = book.author {
                        metadataLine(icon: BookGroup.Kind.author.iconName) {
                            NameListLine(names: [author], open: openAuthor)
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
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        #if os(iOS)
        // The chapter list below competes for vertical space; without this the
        // stack compresses the text into truncation instead of wrapping it.
        .fixedSize(horizontal: false, vertical: true)
        #endif
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

    /// A metadata row with a custom view in the icon column.
    private func metadataLine(@ViewBuilder icon: () -> some View, @ViewBuilder content: () -> some View) -> some View {
        HStack(spacing: 6) {
            icon()
                .frame(width: 22)
            content()
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

    // MARK: - Chapters

    private func chapterList(_ proxy: ScrollViewProxy) -> some View {
        // Computed once per pass: a long book realizes over a thousand rows,
        // so per-row work must stay constant-time.
        let marked = markedChapterIndex
        return List(visibleChapters) { chapter in
                ChapterRow(
                    chapter: chapter,
                    state: rowState(for: chapter, marked: marked),
                    meter: player.audioMeter
                )
                .contentShape(Rectangle())
                .onTapGesture {
                    if isLoaded {
                        Task { await player.jump(to: chapter) }
                    } else if canStartPlayback {
                        player.open(model, playWhenReady: true, startAtSeconds: chapter.startSeconds)
                    }
                }
            }
            .platformChapterListStyle()
            // Keeps the resting rows clear of the floating filter bar.
            .safeAreaInset(edge: .top, spacing: 0) {
                Color.clear.frame(height: floatingBarZoneHeight + 6)
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                Color.clear.frame(height: Self.bottomRestingInset)
            }
            .overlay {
                if chapters.isEmpty {
                    if model.isFetchingChapters {
                        ProgressView()
                    } else {
                        Text("No chapters in this file")
                            .foregroundStyle(.secondary)
                    }
                } else if visibleChapters.isEmpty {
                    ContentUnavailableView.search(text: filterQuery)
                }
            }
            // One trigger for centering: fires on appear and whenever the
            // marked chapter itself moves, instead of on every upstream
            // data change. Each scroll walks the whole row list, so extra
            // firings are expensive on long books.
            // The initial firing passes equal indices; a real chapter move
            // passes different ones and animates.
            .onChange(of: markedChapterIndex, initial: true) { oldIndex, newIndex in
                centerOnTrackedPosition(proxy, animated: oldIndex != newIndex)
            }
            .onUserScroll {
                player.isTrackingPosition = false
            }
            .task(id: book.id) {
                guard !isLoaded else { return }
                // Offline, only a downloaded file can serve chapters, and
                // there is no server to ask or asset to warm.
                guard connection.isServerReachable else {
                    if model.downloadState == .downloaded {
                        await model.fetchChaptersIfNeeded()
                    }
                    return
                }
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
    private func rowState(for chapter: Chapter, marked: Int?) -> ChapterRowState {
        guard let marked else { return .upcoming }
        if chapter.index < marked { return .played }
        if chapter.index > marked { return .upcoming }
        guard isLoaded else { return .current(.bookmark) }
        return .current(player.isPlaying ? .playing : .paused)
    }

    // MARK: - Transcript

    /// True when this book can show a transcript: the server reports a lyric
    /// sidecar, or a fetched transcript is already cached.
    private var hasTranscript: Bool {
        book.hasLyrics == true || !model.lyrics.isEmpty
    }

    /// Space between transcript lines, tight enough to read as running text.
    private static let transcriptLineSpacing: CGFloat = 4

    /// The transcript, marked at the listener's position. The timeline fires
    /// exactly when playback reaches each word, projected through the playback
    /// anchor, so the word mark lands on the boundaries without a fast timer.
    /// The anchor moves on every playback event, rebuilding the schedule.
    private func transcriptList(_ proxy: ScrollViewProxy) -> some View {
        TimelineView(transcriptTickSchedule) { context in
            transcriptText(proxy, at: listeningPosition(at: context.date))
        }
        .task(id: book.id) {
            await model.fetchLyricsIfNeeded()
            centerOnTrackedPosition(proxy, animated: false)
        }
    }

    /// The transcript's redraw schedule, rebuilt whenever the anchor moves.
    /// Reading the anchor and playing state here keeps them observed, so a
    /// playback event re-evaluates the body and replaces the schedule.
    private var transcriptTickSchedule: TranscriptTickSchedule {
        TranscriptTickSchedule(
            tickSeconds: model.transcriptTickSeconds,
            anchor: player.anchor,
            isRunning: isLoaded && player.isPlaying
        )
    }

    private func transcriptText(_ proxy: ScrollViewProxy, at positionSeconds: Double) -> some View {
        let current = currentLineIndex(for: positionSeconds)
        let titleLines = titleLineIndices
        return ScrollView {
            LazyVStack(alignment: .leading, spacing: Self.transcriptLineSpacing) {
                ForEach(visibleLines) { line in
                    LyricLineText(
                        line: line,
                        state: lyricRowState(for: line, current: current),
                        isTitle: titleLines.contains(line.index),
                        positionSeconds: line.index == current ? positionSeconds : nil,
                        onWordTap: { cue in
                            jumpToTranscriptPosition(cue.startSeconds)
                        },
                        onSpokenWordMoved: { midY in
                            followSpokenWord(at: midY, proxy)
                        }
                    )
                    .equatable()
                    .contentShape(Rectangle())
                    .onTapGesture {
                        handleLineTap(line)
                    }
                    .id(line.index)
                }
            }
            .coordinateSpace(name: LyricLineText.contentSpaceName)
            .padding(.horizontal, Self.transcriptHorizontalPadding)
        }
        // While tracking scrolls the transcript, the indicator would flash
        // on every followed row; it returns once the user scrolls themselves.
        .scrollIndicators(player.isTrackingPosition ? .hidden : .automatic)
        // Keeps the resting text clear of the floating filter bar.
        .safeAreaInset(edge: .top, spacing: 0) {
            Color.clear.frame(height: floatingBarZoneHeight + 6)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            Color.clear.frame(height: Self.bottomRestingInset)
        }
        .overlay {
            if model.lyrics.isEmpty {
                if model.isFetchingLyrics {
                    ProgressView()
                } else {
                    Text("No transcript for this book")
                        .foregroundStyle(.secondary)
                }
            } else if visibleLines.isEmpty {
                ContentUnavailableView.search(text: filterQuery)
            }
        }
        .onUserScroll {
            player.isTrackingPosition = false
        }
        // Centers on every current-line change, however far it moved. The
        // geometry-driven follow only reports from a realized row, so a
        // distant jump must go through the realizing scroll.
        .onChange(of: current) { _, _ in
            centerOnTrackedPosition(proxy)
        }
    }

    /// Indices of transcript lines that are chapter headings: the first line
    /// at a chapter's start whose words are exactly the chapter's title,
    /// compared without case. One walk covers both ordered lists.
    private var titleLineIndices: Set<Int> {
        var indices: Set<Int> = []
        let lines = model.lyrics
        var lineIndex = 0
        for chapter in chapters {
            while lineIndex < lines.count, (lines[lineIndex].startSeconds ?? -1) < chapter.startSeconds - 0.5 {
                lineIndex += 1
            }
            guard lineIndex < lines.count else { break }
            let line = lines[lineIndex]
            let lineText = line.text.trimmingCharacters(in: .whitespaces)
            let title = chapter.title.trimmingCharacters(in: .whitespaces)
            if lineText.caseInsensitiveCompare(title) == .orderedSame {
                indices.insert(line.index)
            }
        }
        return indices
    }

    /// The listener's position: the playing position when loaded, or the
    /// resume position in a preview.
    private func listeningPosition(at date: Date) -> Double {
        isLoaded ? player.projectedTime(at: date) : model.resumePositionSeconds
    }

    private func currentLineIndex(at date: Date) -> Int? {
        currentLineIndex(for: listeningPosition(at: date))
    }

    /// The transcript line containing a position. The comparison takes no
    /// slack: the tick dates already land just past each boundary, and any
    /// slack here flips a line to read while its last word is still spoken.
    private func currentLineIndex(for positionSeconds: Double) -> Int? {
        guard positionSeconds > 0 else { return nil }
        return model.lyrics.last(where: { ($0.startSeconds ?? .infinity) <= positionSeconds })?.index
    }

    /// A click beside the words falls back to the line's own start.
    /// Lines without timestamps have no position to go to.
    private func handleLineTap(_ line: LyricLine) {
        guard let start = line.startSeconds else { return }
        jumpToTranscriptPosition(start)
    }

    /// Seeks a loaded book to the position, or starts playback there in a preview.
    private func jumpToTranscriptPosition(_ seconds: Double) {
        if isLoaded {
            Task { await player.jump(toSeconds: seconds) }
        } else if canStartPlayback {
            player.open(model, playWhenReady: true, startAtSeconds: seconds)
        }
    }

    /// Kicks the event-based row follow. The marker cannot be scrolled to
    /// before the lazy stack realizes its row, so the line scroll runs first
    /// to realize it; once the marker has a frame, its scroll wins and the
    /// kick lands on the spoken row. On a fresh realization the marker's
    /// first geometry report follows up with the exact centering.
    private func scrollToSpokenWord(_ proxy: ScrollViewProxy) {
        if let index = currentLineIndex(at: Date()),
           visibleLines.contains(where: { $0.index == index }) {
            proxy.scrollTo(index, anchor: .center)
        }
        proxy.scrollTo(LyricLineText.spokenWordID, anchor: .center)
    }

    /// Follows the narration onto a new wrapped row. The spoken word reports
    /// its height whenever it moves; words on one row share it, so tracking
    /// scrolls once per wrapped row, not once per word.
    private func followSpokenWord(at midY: CGFloat, _ proxy: ScrollViewProxy) {
        let movedRows = abs((trackedWordY ?? -.infinity) - midY) > 1
        trackedWordY = midY
        guard player.isTrackingPosition, movedRows else { return }
        withAnimation { proxy.scrollTo(LyricLineText.spokenWordID, anchor: .center) }
    }

    private func lyricRowState(for line: LyricLine, current: Int?) -> LyricRowState {
        guard let current else { return .upcoming }
        if line.index < current { return .played }
        if line.index > current { return .upcoming }
        return .current
    }
}

/// Fires at each transcript tick moment, projected through the playback
/// anchor, with a few milliseconds of slack placing each redraw just past
/// its boundary so the projected position always covers the word. Entries
/// generate lazily on demand, so replacing the schedule after an anchor
/// change allocates nothing per remaining cue. Empty while nothing moves,
/// so a paused transcript never redraws.
private struct TranscriptTickSchedule: TimelineSchedule {
    /// The tick moments as positions, sorted without duplicates.
    let tickSeconds: [Double]
    let anchor: PlaybackAnchor
    let isRunning: Bool

    /// Delay after each boundary, keeping the redraw just past it.
    private static let slack: TimeInterval = 0.005

    func entries(from startDate: Date, mode: TimelineScheduleMode) -> AnySequence<Date> {
        guard isRunning, anchor.rate > 0 else { return AnySequence([]) }
        let anchor = anchor
        let position = anchor.position(at: startDate)
        let upcoming = tickSeconds[firstIndex(after: position)...]
        return AnySequence(upcoming.lazy.compactMap { seconds in
            anchor.date(forPosition: seconds)?.addingTimeInterval(Self.slack)
        })
    }

    /// The index of the first tick strictly past the position, found by
    /// binary search.
    private func firstIndex(after position: Double) -> Int {
        var low = 0
        var high = tickSeconds.count
        while low < high {
            let mid = (low + high) / 2
            if tickSeconds[mid] <= position {
                low = mid + 1
            } else {
                high = mid
            }
        }
        return low
    }
}

private extension View {
    /// Runs the action when the user scrolls the view themselves. The
    /// animating phase of programmatic centering does not count.
    func onUserScroll(perform action: @escaping () -> Void) -> some View {
        onScrollPhaseChange { _, newPhase in
            switch newPhase {
            case .tracking, .interacting:
                action()
            default:
                break
            }
        }
    }

    /// Edge-to-edge rows on the phone; the inset style on the Mac.
    func platformChapterListStyle() -> some View {
        #if os(iOS)
        return listStyle(.plain)
        #else
        return listStyle(.inset)
        #endif
    }
}

/// On the phone the chapter list runs under the home indicator, so the fade
/// lands at the true screen bottom. The Mac window has no such inset.
private struct ExtendToScreenBottom: ViewModifier {
    func body(content: Content) -> some View {
        #if os(iOS)
        content.ignoresSafeArea(edges: .bottom)
        #else
        content
        #endif
    }
}

private extension BookView {
    /// Resting clearance for the last row: past the fade, and past the home
    /// indicator on the phone.
    static var bottomRestingInset: CGFloat {
        #if os(iOS)
        return 44
        #else
        return 16
        #endif
    }

    /// Side padding of the transcript text: the phone's content padding, and
    /// the inset list's margin on the Mac.
    static var transcriptHorizontalPadding: CGFloat {
        #if os(iOS)
        return 20
        #else
        return 12
        #endif
    }
}

/// A comma-separated list of names wrapping like text, each name its own
/// click-and-hover target navigating to that name's books when the shell
/// provides a destination.
private struct NameListLine: View {
    let names: [String]
    let open: OpenBookGroupAction?

    @State private var hoveredName: String?

    var body: some View {
        FlowLayout(alignment: .leading) {
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
