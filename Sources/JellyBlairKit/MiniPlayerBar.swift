import SwiftUI

/// Compact playback bar shown while a book is loaded and its screen is not
/// visible. Tapping the info area navigates back to the book's screen.
public struct MiniPlayerBar: View {
    let onTap: () -> Void

    @Environment(PlayerController.self) private var player
    @Environment(BookCatalog.self) private var catalog

    public init(onTap: @escaping () -> Void) {
        self.onTap = onTap
    }

    public var body: some View {
        if let book = player.book {
            HStack(spacing: 12) {
                HStack(spacing: 12) {
                    BookCoverImage(bookID: book.id, url: catalog.coverURL(for: book), contentMode: .fill)
                        .frame(width: 40, height: 40)
                        .clipShape(RoundedRectangle(cornerRadius: 6))

                    VStack(alignment: .leading, spacing: 2) {
                        Text(player.currentChapter?.title ?? book.name)
                            .font(.callout.weight(.semibold))
                            .lineLimit(1)
                        subtitle(for: book)
                    }

                    Spacer(minLength: 8)
                }
                .contentShape(Rectangle())
                .onTapGesture(perform: onTap)

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
                        .contentTransition(.identity)
                        .animation(nil, value: player.isPlaying)
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

    @ViewBuilder
    private func subtitle(for book: Book) -> some View {
        if let message = player.playbackErrorMessage {
            Text(message)
                .font(.caption)
                .foregroundStyle(.red)
                .lineLimit(1)
        } else {
            Text(book.name)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }
}

