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
    /// The handle the tracking button centers the transcript through.
    @State private var transcriptController = TranscriptController()
    @State private var isHoveringDownload = false

    /// The position of the matching chapter the arrows navigated to. The
    /// transcript's counterpart lives in its controller.
    @State private var chapterMatchIndex = 0

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

    /// The search phrase, without surrounding whitespace.
    private var trimmedQuery: String {
        filterQuery.trimmingCharacters(in: .whitespaces)
    }

    /// Ids of the chapters whose titles contain the query.
    private var matchingChapterIDs: [Int] {
        guard !trimmedQuery.isEmpty else { return [] }
        return chapters.filter { $0.title.range(of: trimmedQuery, options: .caseInsensitive) != nil }.map(\.index)
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
        .keepsScreenAwake(keepsScreenAwake, reason: "The transcript follows the narration")
    }

    /// The screen stays awake while the playing transcript follows the
    /// narration; a paused or previewed book lets it sleep, since its
    /// transcript does not move.
    private var keepsScreenAwake: Bool {
        isShowingTranscript && player.isTrackingPosition && isLoaded && player.isPlaying
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
                // Both lists stay alive; the toggle changes only which one
                // shows. The hidden transcript keeps tracking the narration,
                // so switching to it opens on the current word without any
                // repositioning.
                ZStack {
                    chapterList(proxy)
                        .opacity(isShowingTranscript ? 0 : 1)
                        .allowsHitTesting(!isShowingTranscript)
                    if hasTranscript {
                        transcriptList
                            .opacity(isShowingTranscript ? 1 : 0)
                            .allowsHitTesting(isShowingTranscript)
                    }
                }
                .fadedUnderFloatingBar(fadesBottom: true)
                // The bar's height comes from the search field; the capsule
                // buttons stretch to match it exactly.
                HStack(spacing: 8) {
                    filterField(proxy)
                    if hasTranscript {
                        transcriptToggle
                    }
                    trackingButton(proxy)
                }
                .fixedSize(horizontal: false, vertical: true)
                #if os(iOS)
                .padding(.horizontal, 20)
                #endif
            }
            .onChange(of: filterQuery) { _, _ in
                guard !isShowingTranscript else { return }
                chapterMatchIndex = 0
                guard !trimmedQuery.isEmpty else { return }
                jumpToNearestChapterMatch(proxy)
            }
        }
    }

    /// Steps the showing view's search one match forward or backward.
    private func stepMatch(by delta: Int, _ proxy: ScrollViewProxy) {
        if isShowingTranscript {
            transcriptController.stepMatch(by: delta)
        } else {
            jumpToChapterMatch(chapterMatchIndex + delta, proxy)
        }
    }

    /// A fresh query lands on the first matching chapter at or past the
    /// marked one, like find starting from a cursor.
    private func jumpToNearestChapterMatch(_ proxy: ScrollViewProxy) {
        let ids = matchingChapterIDs
        guard !ids.isEmpty else { return }
        let marked = markedChapterIndex ?? 0
        jumpToChapterMatch(ids.firstIndex(where: { $0 >= marked }) ?? 0, proxy)
    }

    private func jumpToChapterMatch(_ index: Int, _ proxy: ScrollViewProxy) {
        let ids = matchingChapterIDs
        guard !ids.isEmpty else { return }
        chapterMatchIndex = (index + ids.count) % ids.count
        withAnimation { proxy.scrollTo(ids[chapterMatchIndex], anchor: .center) }
        player.isTrackingPosition = false
    }

    /// Toggles tracking, which is on by default and shared across books.
    /// Turning it on centers the position right away. Scrolling the list by
    /// hand or jumping to a search match turns tracking off.
    private func trackingButton(_ proxy: ScrollViewProxy) -> some View {
        CapsuleIconButton(
            "scope",
            isOn: player.isTrackingPosition,
            help: player.isTrackingPosition ? "Stop following the listening position" : "Follow the listening position"
        ) {
            player.isTrackingPosition.toggle()
            guard player.isTrackingPosition else { return }
            Task { @MainActor in
                centerOnTrackedPosition(proxy)
            }
        }
    }

    /// Centers the listener's position while tracking is on. Every centering
    /// goes through here: opening a book, pressing the tracking button, and
    /// the marked chapter moving. The unanimated form serves openings, where
    /// an animated scroll would glide across the whole list.
    private func centerOnTrackedPosition(_ proxy: ScrollViewProxy, animated: Bool = true) {
        guard player.isTrackingPosition else { return }
        if isShowingTranscript {
            transcriptController.centerOnSpokenWord(animated: animated)
        } else if animated {
            withAnimation { scrollToMarkedChapter(proxy) }
        } else {
            scrollToMarkedChapter(proxy)
        }
    }

    /// Swaps the list below between the chapters and the transcript.
    /// The icon shows the view the button switches to.
    private var transcriptToggle: some View {
        CapsuleIconButton(
            isShowingTranscript ? "list.bullet" : "text.quote",
            help: isShowingTranscript ? "Show the chapters" : "Show the transcript"
        ) {
            filterQuery = ""
            isShowingTranscript.toggle()
        }
    }

    private func filterField(_ proxy: ScrollViewProxy) -> some View {
        CapsuleSearchField(isShowingTranscript ? "Search Transcript" : "Search Chapters", text: $filterQuery) {
            if !trimmedQuery.isEmpty {
                matchNavigator(proxy)
            }
        }
        .onSubmit {
            stepMatch(by: 1, proxy)
        }
    }

    /// Ghost find controls at the search field's right edge: the match
    /// position and arrows stepping through the matches.
    private func matchNavigator(_ proxy: ScrollViewProxy) -> some View {
        let count = isShowingTranscript ? transcriptController.matchCount : matchingChapterIDs.count
        let index = isShowingTranscript ? transcriptController.matchIndex : chapterMatchIndex
        let searching = isShowingTranscript && transcriptController.isSearching
        return HStack(spacing: 4) {
            if searching {
                ProgressView()
                    .controlSize(.mini)
            } else {
                Text(count == 0 ? "0/0" : "\(index + 1)/\(count)")
                    .monospacedDigit()
            }
            Button {
                stepMatch(by: -1, proxy)
            } label: {
                Image(systemName: "chevron.left")
            }
            .buttonStyle(.plain)
            .disabled(count == 0 || searching)
            Button {
                stepMatch(by: 1, proxy)
            } label: {
                Image(systemName: "chevron.right")
            }
            .buttonStyle(.plain)
            .disabled(count == 0 || searching)
        }
        .font(.caption)
        .foregroundStyle(.tertiary)
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
        return List(chapters) { chapter in
                ChapterRow(
                    chapter: chapter,
                    state: rowState(for: chapter, marked: marked),
                    meter: player.audioMeter,
                    searchQuery: trimmedQuery
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
        guard let index = markedChapterIndex else { return }
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

    /// The transcript, marked at the listener's position. The timeline fires
    /// exactly when playback reaches each word, projected through the playback
    /// anchor, so the word mark lands on the boundaries without a fast timer.
    /// The anchor moves on every playback event, rebuilding the schedule.
    private var transcriptList: some View {
        let lines = model.lyrics
        let chapters = chapters
        return TimelineView(transcriptTickSchedule) { context in
            transcriptText(at: listeningPosition(at: context.date), lines: lines, chapters: chapters)
        }
        .task(id: book.id) {
            await model.fetchLyricsIfNeeded()
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

    private func transcriptText(at positionSeconds: Double, lines: [LyricLine], chapters: [Chapter]) -> some View {
        TranscriptTextView(
            lines: lines,
            chapters: chapters,
            positionSeconds: positionSeconds,
            isTracking: player.isTrackingPosition,
            isVisible: isShowingTranscript,
            // The hidden transcript does not search, so typing a chapter
            // query cannot scroll it or turn tracking off.
            searchQuery: isShowingTranscript ? trimmedQuery : "",
            topInset: floatingBarZoneHeight + 6,
            bottomInset: Self.bottomRestingInset,
            horizontalPadding: Self.transcriptHorizontalPadding,
            controller: transcriptController,
            onWordTap: { cue in
                jumpToTranscriptPosition(cue.startSeconds)
            },
            onUserScroll: {
                player.isTrackingPosition = false
            }
        )
        .overlay {
            if model.lyrics.isEmpty {
                if model.isFetchingLyrics {
                    ProgressView()
                } else {
                    Text("No transcript for this book")
                        .foregroundStyle(.secondary)
                }
            } else if transcriptController.isPreparingLayout {
                ProgressView()
            }
        }
    }

    /// The listener's position: the playing position when loaded, or the
    /// resume position in a preview.
    private func listeningPosition(at date: Date) -> Double {
        isLoaded ? player.projectedTime(at: date) : model.resumePositionSeconds
    }

    /// Seeks a loaded book to the position, or starts playback there in a preview.
    private func jumpToTranscriptPosition(_ seconds: Double) {
        if isLoaded {
            Task { await player.jump(toSeconds: seconds) }
        } else if canStartPlayback {
            player.open(model, playWhenReady: true, startAtSeconds: seconds)
        }
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
