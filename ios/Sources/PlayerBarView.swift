import JellyBlairKit
import SwiftUI

/// Compact playback bar pinned above the bottom edge while a book is loaded.
struct PlayerBarView: View {
    let player: PlayerController
    let client: JellyfinClient

    var body: some View {
        if let book = player.book {
            HStack(spacing: 12) {
                BookCoverImage(bookID: book.id, url: client.imageURL(for: book), contentMode: .fill)
                    .frame(width: 40, height: 40)
                    .clipShape(RoundedRectangle(cornerRadius: 6))

                VStack(alignment: .leading, spacing: 2) {
                    Text(player.currentChapter?.title ?? book.name)
                        .font(.callout.weight(.semibold))
                        .lineLimit(1)
                    Text(book.name)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer()

                Button {
                    Task { await player.skip(by: -30) }
                } label: {
                    Image(systemName: "gobackward.30").font(.title3)
                }

                Button {
                    player.togglePlayback()
                } label: {
                    Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                        .font(.title2)
                        .frame(width: 32)
                }
            }
            .buttonStyle(.plain)
            .disabled(!player.isReady)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(.bar)
            .overlay(alignment: .top) {
                Divider()
            }
        }
    }
}
