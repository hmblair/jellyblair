import SwiftUI

/// The chapter list with its own floating search bar and tracking button.
/// The search state and the tracking flag are pane-local.
struct ChapterListPane: View {
    let book: Book
    let model: BookModel
    let chapters: [Chapter]
    /// The chapter marked as current, from the playing or resume position.
    let marked: Int?
    let isLoaded: Bool
    let canStartPlayback: Bool

    @Environment(PlayerController.self) private var player
    @Environment(ConnectionMonitor.self) private var connection
    @Environment(\.scenePhase) private var scenePhase

    @State private var query = ""
    @State private var isCaseSensitive = false
    /// The position of the matching chapter the arrows navigated to.
    @State private var matchIndex = 0
    /// Whether the list follows the marked chapter. On by default; scrolling
    /// by hand or jumping to a search match turns it off.
    @State private var isTracking = true

    /// Ids of the chapters whose titles contain the query.
    private var matchingChapterIDs: [Int] {
        guard !query.isEmpty else { return [] }
        return chapters
            .filter { !findOccurrences(of: query, in: $0.title as NSString, caseSensitive: isCaseSensitive, limit: 1).isEmpty }
            .map(\.index)
    }

    var body: some View {
        ScrollViewReader { proxy in
            list(proxy)
                .floatingSearchBar {
                    searchField(proxy)
                    trackingButton(proxy)
                }
                .onChange(of: query) { _, _ in
                    restartSearch(proxy)
                }
                .onChange(of: isCaseSensitive) { _, _ in
                    restartSearch(proxy)
                }
        }
    }

    private func list(_ proxy: ScrollViewProxy) -> some View {
        List(chapters) { chapter in
                ChapterRow(
                    chapter: chapter,
                    state: rowState(for: chapter),
                    meter: player.audioMeter,
                    searchQuery: query,
                    searchIsCaseSensitive: isCaseSensitive
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
                Color.clear.frame(height: PaneLayout.bottomRestingInset)
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
            .onChange(of: marked, initial: true) { oldIndex, newIndex in
                centerOnMarked(proxy, animated: oldIndex != newIndex)
            }
            .onUserScroll {
                isTracking = false
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

    /// Played and upcoming are positional relative to the marked chapter,
    /// so the list mirrors the book's progress.
    private func rowState(for chapter: Chapter) -> ChapterRowState {
        guard let marked else { return .upcoming }
        if chapter.index < marked { return .played }
        if chapter.index > marked { return .upcoming }
        guard isLoaded else { return .current(.bookmark) }
        return .current(player.isPlaying ? .playing : .paused)
    }

    // MARK: - Search

    private func searchField(_ proxy: ScrollViewProxy) -> some View {
        CapsuleSearchField("Search Chapters", text: $query) {
            if !query.isEmpty {
                MatchNavigator(isCaseSensitive: $isCaseSensitive, count: matchingChapterIDs.count, index: matchIndex, isSearching: false) { delta in
                    step(by: delta, proxy)
                }
            }
        }
        .stepsMatchesOnSubmit { delta in
            step(by: delta, proxy)
        }
    }

    private func step(by delta: Int, _ proxy: ScrollViewProxy) {
        jump(to: matchIndex + delta, proxy)
    }

    /// Restarts the match position after the query or its sensitivity changes.
    private func restartSearch(_ proxy: ScrollViewProxy) {
        matchIndex = 0
        guard !query.isEmpty else { return }
        jumpToNearestMatch(proxy)
    }

    /// A fresh query lands on the first matching chapter at or past the
    /// marked one, like find starting from a cursor.
    private func jumpToNearestMatch(_ proxy: ScrollViewProxy) {
        let ids = matchingChapterIDs
        guard !ids.isEmpty else { return }
        jump(to: ids.firstIndex(where: { $0 >= (marked ?? 0) }) ?? 0, proxy)
    }

    private func jump(to index: Int, _ proxy: ScrollViewProxy) {
        let ids = matchingChapterIDs
        guard !ids.isEmpty else { return }
        matchIndex = (index % ids.count + ids.count) % ids.count
        withAnimation { proxy.scrollTo(ids[matchIndex], anchor: .center) }
        isTracking = false
    }

    // MARK: - Tracking

    /// Toggles following the marked chapter. Turning it on centers right away.
    private func trackingButton(_ proxy: ScrollViewProxy) -> some View {
        CapsuleIconButton(
            "scope",
            isOn: isTracking,
            help: isTracking ? "Stop following the listening position" : "Follow the listening position"
        ) {
            isTracking.toggle()
            guard isTracking else { return }
            Task { @MainActor in
                centerOnMarked(proxy, animated: true)
            }
        }
    }

    /// Centers the marked chapter while tracking is on. The unanimated form
    /// serves openings, where an animated scroll would glide across the
    /// whole list.
    private func centerOnMarked(_ proxy: ScrollViewProxy, animated: Bool) {
        guard isTracking, let marked else { return }
        if animated {
            withAnimation { proxy.scrollTo(marked, anchor: .center) }
        } else {
            proxy.scrollTo(marked, anchor: .center)
        }
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
