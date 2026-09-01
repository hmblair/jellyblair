import SwiftUI

/// Compact playback bar shown while a book is loaded and its screen is not
/// visible. Tapping the info area navigates back to the book's screen.
public struct MiniPlayerBar: View {
    let player: PlayerController
    let client: JellyfinClient
    let onTap: () -> Void

    public init(player: PlayerController, client: JellyfinClient, onTap: @escaping () -> Void) {
        self.player = player
        self.client = client
        self.onTap = onTap
    }

    public var body: some View {
        if let book = player.book {
            HStack(spacing: 12) {
                HStack(spacing: 12) {
                    BookCoverImage(bookID: book.id, url: client.imageURL(for: book), contentMode: .fill)
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

/// A sidebar or list row for one book, with a speaker mark on the loaded one.
public struct BookRow: View {
    let book: Book
    let imageURL: URL
    let isLoaded: Bool

    public init(book: Book, imageURL: URL, isLoaded: Bool) {
        self.book = book
        self.imageURL = imageURL
        self.isLoaded = isLoaded
    }

    public var body: some View {
        HStack(spacing: 10) {
            BookCoverImage(bookID: book.id, url: imageURL, contentMode: .fill)
                .frame(width: 44, height: 44)
                .clipShape(RoundedRectangle(cornerRadius: 6))

            VStack(alignment: .leading, spacing: 2) {
                Text(book.name)
                    .lineLimit(1)
                Text(formatTime(book.runTimeSeconds))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            if isLoaded {
                Spacer()
                Image(systemName: "speaker.wave.2.fill")
                    .font(.caption)
                    .foregroundStyle(Color.accentColor)
            }
        }
        .padding(.vertical, 2)
    }
}
