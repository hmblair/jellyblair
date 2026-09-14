import SwiftUI

/// A sidebar or list row for one book, with level bars on the loaded one.
public struct BookRow: View {
    let book: Book
    let isLoaded: Bool

    @Environment(PlayerController.self) private var player

    public init(book: Book, isLoaded: Bool) {
        self.book = book
        self.isLoaded = isLoaded
    }

    @State private var isHovering = false

    public var body: some View {
        HStack(spacing: 10) {
            BookCoverImage(bookID: book.id, url: book.coverURL, contentMode: .fill)
                .frame(width: 44, height: 44)
                .clipShape(RoundedRectangle(cornerRadius: 6))

            VStack(alignment: .leading, spacing: 2) {
                Text(book.name)
                    .font(.title3)
                    .lineLimit(1)
                detailLine
            }

            Spacer()

            if isLoaded {
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

    /// The row's second line: the first author, the year, and the length.
    /// The author truncates first when the row is narrow; the rest keeps
    /// its size.
    private var detailLine: some View {
        HStack(spacing: 0) {
            if let author = book.authors.first {
                Text(author)
                    .lineLimit(1)
            }
            Text(fixedDetailText)
                .fixedSize()
        }
        .font(.footnote)
        .foregroundStyle(.secondary)
    }

    /// The detail line's fixed tail: the year when known, then the length,
    /// with a leading separator when an author precedes them.
    private var fixedDetailText: String {
        var parts: [String] = []
        if let year = book.productionYear {
            parts.append(String(year))
        }
        parts.append(formatHoursMinutes(book.runTimeSeconds))
        let tail = parts.joined(separator: " · ")
        return book.authors.isEmpty ? tail : " · " + tail
    }
}

/// A group heading: the group's name centered over the kind, count, and
/// length line, clickable across its full width when it has an action. On
/// the Mac a back chevron sits at the leading edge.
public struct GroupHeading: View {
    let heading: BookListHeading
    let showsBackChevron: Bool
    let action: (() -> Void)?

    public init(_ heading: BookListHeading, showsBackChevron: Bool = false, action: (() -> Void)? = nil) {
        self.heading = heading
        self.showsBackChevron = showsBackChevron
        self.action = action
    }

    public var body: some View {
        if let action {
            Button(action: action) {
                label
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        } else {
            label
        }
    }

    private var label: some View {
        VStack(spacing: 2) {
            Text(heading.name)
                .font(.title2.bold())
                .foregroundStyle(.primary)
            Text(verbatim: heading.detail)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity)
        // The chevron overlays the edge, so the lines center on the full
        // width rather than beside it.
        .overlay(alignment: .leading) {
            if showsBackChevron {
                Image(systemName: "chevron.left")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        // The list's header style would upcase the name; the heading keeps
        // its own case.
        .textCase(nil)
        .padding(.vertical, 6)
    }
}
