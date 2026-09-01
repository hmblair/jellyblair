import JellyBlairKit
import SwiftUI

/// One book: cover, metadata, transport controls, seek bar, and chapters.
struct BookScreen: View {
    let book: Book
    let player: PlayerController
    let client: JellyfinClient

    @State private var isAutoScrollWindowOpen = true

    var body: some View {
        VStack(spacing: 12) {
            header
            if let message = player.playbackErrorMessage {
                errorBanner(message)
            }
            SeekBarView(player: player)
            TransportControlsView(player: player)
            Divider()
            chapterList
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .navigationBarTitleDisplayMode(.inline)
        .task(id: book.id) {
            if player.book?.id != book.id {
                player.open(book)
            }
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 14) {
            BookCoverImage(bookID: book.id, url: client.imageURL(for: book), contentMode: .fit)
                .frame(width: 110, height: 110)
                .clipShape(RoundedRectangle(cornerRadius: 10))

            VStack(alignment: .leading, spacing: 4) {
                Text(book.name)
                    .font(.headline)
                Text(book.authorAndRuntimeText)
                    .font(.subheadline)
                if let narrator = book.narrator {
                    Text("Narrated by \(narrator)")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                RemainingTimeView(player: player)
            }
            Spacer()
        }
        .frame(height: 110)
    }

    private func errorBanner(_ message: String) -> some View {
        HStack {
            Label(message, systemImage: "exclamationmark.triangle")
                .font(.footnote)
                .foregroundStyle(.red)
            Spacer()
            Button("Retry") {
                player.retryCurrentBook()
            }
            .font(.footnote)
        }
    }

    private var chapterList: some View {
        ScrollViewReader { proxy in
            List(player.chapters) { chapter in
                ChapterRow(
                    chapter: chapter,
                    state: rowState(for: chapter),
                    isPlaying: player.isPlaying,
                    meter: player.audioMeter
                )
                .contentShape(Rectangle())
                .onTapGesture {
                    Task { await player.jump(to: chapter) }
                }
            }
            .listStyle(.plain)
            .overlay {
                if player.chapters.isEmpty {
                    Text("No chapters in this file")
                        .foregroundStyle(.secondary)
                }
            }
            .onAppear {
                scrollToCurrentChapter(proxy)
            }
            .onChange(of: player.chapters) {
                scrollToCurrentChapter(proxy)
            }
            .onChange(of: player.currentChapterIndex) {
                guard isAutoScrollWindowOpen else { return }
                scrollToCurrentChapter(proxy)
            }
            .task {
                try? await Task.sleep(for: .seconds(3))
                isAutoScrollWindowOpen = false
            }
        }
    }

    /// Centers the list on the current chapter shortly after opening,
    /// then disarms so playback does not move a list being browsed.
    private func scrollToCurrentChapter(_ proxy: ScrollViewProxy) {
        guard let index = player.currentChapterIndex else { return }
        proxy.scrollTo(index, anchor: .center)
    }

    /// Played and upcoming are positional: everything before the current
    /// chapter reads as played, so the list mirrors the book's progress.
    private func rowState(for chapter: Chapter) -> ChapterRowState {
        guard let current = player.currentChapterIndex else { return .upcoming }
        if chapter.index < current { return .played }
        if chapter.index == current { return .current }
        return .upcoming
    }
}
