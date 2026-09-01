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

/// A sidebar or list row for one book, with level bars on the loaded one.
public struct BookRow: View {
    let book: Book
    let isLoaded: Bool

    @Environment(BookCatalog.self) private var catalog
    @Environment(PlayerController.self) private var player

    public init(book: Book, isLoaded: Bool) {
        self.book = book
        self.isLoaded = isLoaded
    }

    @State private var isHovering = false

    public var body: some View {
        HStack(spacing: 10) {
            BookCoverImage(bookID: book.id, url: catalog.coverURL(for: book), contentMode: .fill)
                .frame(width: 44, height: 44)
                .clipShape(RoundedRectangle(cornerRadius: 6))

            VStack(alignment: .leading, spacing: 2) {
                Text(book.name)
                    .lineLimit(1)
                Text(formatHoursMinutes(book.runTimeSeconds))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            if isLoaded {
                Spacer()
                AudioBarsView(meter: player.audioMeter, isPlaying: player.isPlaying)
            }
        }
        .padding(.vertical, 2)
        // The row stretches to the full cell width, so hover responds
        // anywhere the click does.
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        // The hover pill mimics the system selection pill. Its geometry is
        // not exposed by SwiftUI, so these insets mirror it by observation
        // and may need retuning after a macOS update.
        .listRowBackground(
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.primary.opacity(0.06))
                .opacity(isHovering ? 1 : 0)
                .animation(.easeOut(duration: 0.1), value: isHovering)
                .padding(.horizontal, 10)
        )
        .onHover { isHovering = $0 }
    }
}

/// An author section heading: plain text in the platform's header style,
/// clickable across its full width to open the author's books.
public struct AuthorHeading: View {
    let name: String
    let action: () -> Void

    public init(name: String, action: @escaping () -> Void) {
        self.name = name
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            HStack {
                Text(name)
                Spacer()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
