import SwiftUI

/// The book's cover as the header's square, with its shadow.
struct BookPlayerCover: View {
    let book: Book

    @Environment(\.layoutMetrics) private var metrics

    var body: some View {
        BookCoverImage(bookID: book.id, url: book.coverURL, contentMode: .fit)
            .frame(width: metrics.bookScreen.playerCoverSize, height: metrics.bookScreen.playerCoverSize)
            .clipShape(RoundedRectangle(cornerRadius: metrics.bookScreen.coverCornerRadius))
            .shadow(color: .black.opacity(0.25), radius: 18, y: 10)
    }
}

/// One prominent action in place of a transport, shown only for a book
/// that is not loaded: it resumes or starts the book on this screen. The
/// loaded book's screen shows no button, so a missing button beside the
/// bar reads as "this book is in the player".
struct BookPlayButton: View {
    let book: Book
    /// Whether the book can start; the screen owns the offline rule.
    let canStart: Bool

    @Environment(PlayerController.self) private var player
    @Environment(\.layoutMetrics) private var metrics

    var body: some View {
        Button {
            player.open(book, playWhenReady: true)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "play.fill")
                if book.isStarted {
                    Text("Resume")
                } else {
                    Text("Play")
                }
            }
            .frame(minWidth: 100)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(metrics.bookScreen.playButtonControlSize)
        .disabled(!canStart)
    }
}

/// The resume chapter and the remaining listening time, or the whole
/// length of a book not yet started.
struct BookPlaybackCaption: View {
    let book: Book

    @Environment(\.layoutMetrics) private var metrics

    var body: some View {
        Group {
            if book.isStarted {
                let remaining = formatHoursMinutes(book.runTimeSeconds - book.resumePositionSeconds)
                if let title = book.resumeChapter?.title {
                    Text("\(title) · \(remaining) remaining")
                } else {
                    Text("\(remaining) remaining")
                }
            } else {
                Text(formatHoursMinutes(book.runTimeSeconds))
            }
        }
        .font(metrics.bookScreen.detailFont)
        .foregroundStyle(.secondary)
        .lineLimit(1)
    }
}

/// The title over the metadata lines: each line a step smaller and dimmer
/// than the one above, so the type carries the hierarchy. The lines wrap,
/// following the given alignment.
struct BookTitleBlock: View {
    let book: Book
    let alignment: HorizontalAlignment

    @Environment(\.openBookGroup) private var openBookGroup
    @Environment(\.layoutMetrics) private var metrics

    var body: some View {
        VStack(alignment: alignment, spacing: 6) {
            titleLines
            creditLines
            publisherYearLine
            genreLine
        }
        .multilineTextAlignment(alignment == .center ? .center : .leading)
    }

    /// The title over its subtitle, the subtitle one step smaller and
    /// dimmer. A title with no colon shows one line.
    @ViewBuilder
    private var titleLines: some View {
        Text(book.mainTitle)
            .font(metrics.bookScreen.titleFont)
        if let subtitle = book.subtitle {
            Text(subtitle)
                .font(metrics.bookScreen.subtitleFont)
                .foregroundStyle(.secondary)
        }
    }

    /// One credit line per group of roles naming the same people, from
    /// "Written by" through "Written, translated, and read by". Every
    /// name opens the person's shelf, whichever roles it holds.
    private var creditLines: some View {
        ForEach(book.credits, id: \.self) { credit in
            creditLine(prefix: credit.roles.creditPrefix, names: credit.names)
        }
    }

    private func creditLine(prefix: String, names: [String]) -> some View {
        namesLine(prefix: prefix, kind: .person, names: names)
            .font(metrics.bookScreen.lineFont)
            .foregroundStyle(.secondary)
    }

    /// The publisher names and the year on one line, the block's quietest.
    @ViewBuilder
    private var publisherYearLine: some View {
        let names = BookGroup.Kind.publisher.names(of: book)
        let year = book.productionYear
        Group {
            if !names.isEmpty {
                namesLine(kind: .publisher, names: names, suffix: year.map { "· \($0)" })
            } else if let year {
                Text(verbatim: String(year))
            }
        }
        .font(metrics.bookScreen.detailFont)
        .foregroundStyle(.tertiary)
    }

    /// The genres joined by dots, each opening its genre shelf. Dots
    /// instead of commas, since genres read as tags rather than names.
    @ViewBuilder
    private var genreLine: some View {
        let names = BookGroup.Kind.genre.names(of: book)
        if !names.isEmpty {
            dottedLine(kind: .genre, names: names)
                .font(metrics.bookScreen.detailFont)
                .foregroundStyle(.tertiary)
        }
    }

    /// One line naming a group's members with dot separators, each name
    /// its own hover-and-click target. A dot lives with the name before
    /// it, so a wrap never strands one.
    private func dottedLine(kind: BookGroup.Kind, names: [String]) -> some View {
        FlowLine(alignment: alignment) {
            ForEach(Array(names.enumerated()), id: \.offset) { index, name in
                HStack(spacing: 4) {
                    GroupNameButton(kind: kind, name: name, open: openBookGroup)
                    if index < names.count - 1 {
                        Text(verbatim: "·")
                    }
                }
            }
        }
    }

    /// One line naming a group's members — "x", "x and y", or "x, y, and
    /// z" — with each name its own hover-and-click target. The words flow
    /// and wrap like text; a comma lives with the name before it, so a
    /// wrap never strands one.
    private func namesLine(
        prefix: String? = nil,
        kind: BookGroup.Kind,
        names: [String],
        suffix: String? = nil
    ) -> some View {
        FlowLine(alignment: alignment) {
            if let prefix {
                Text(verbatim: prefix)
            }
            ForEach(Array(names.enumerated()), id: \.offset) { index, name in
                HStack(spacing: 0) {
                    GroupNameButton(kind: kind, name: name, open: openBookGroup)
                    if names.count > 2, index < names.count - 1 {
                        Text(verbatim: ",")
                    }
                }
                if index == names.count - 2 {
                    Text("and")
                }
            }
            if let suffix {
                Text(verbatim: suffix)
            }
        }
    }
}

/// One name as its own hover-and-click target, navigating to the name's
/// books when the shell provides a destination.
private struct GroupNameButton: View {
    let kind: BookGroup.Kind
    let name: String
    let open: OpenBookGroupAction?

    @State private var isHovering = false

    var body: some View {
        if let open {
            Button {
                open(kind, name)
            } label: {
                Text(name)
                    .opacity(isHovering ? 0.6 : 1)
                    .animation(.easeOut(duration: 0.1), value: isHovering)
            }
            .buttonStyle(.plain)
            .onHover { isHovering = $0 }
        } else {
            Text(name)
        }
    }
}

/// Lays out its children like words in wrapped text: rows fill greedily
/// left to right, and each row aligns to the leading edge or the center.
private struct FlowLine: Layout {
    let alignment: HorizontalAlignment
    var spacing: CGFloat = 4
    var rowSpacing: CGFloat = 2

    private struct Row {
        var range: Range<Int>
        var width: CGFloat
        var height: CGFloat
    }

    private func rows(of subviews: Subviews, inWidth maxWidth: CGFloat) -> [Row] {
        var rows: [Row] = []
        var start = 0
        var width: CGFloat = 0
        var height: CGFloat = 0
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            let widthWithChild = width == 0 ? size.width : width + spacing + size.width
            if width > 0, widthWithChild > maxWidth {
                rows.append(Row(range: start..<index, width: width, height: height))
                start = index
                width = size.width
                height = size.height
            } else {
                width = widthWithChild
                height = max(height, size.height)
            }
        }
        rows.append(Row(range: start..<subviews.count, width: width, height: height))
        return rows
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = rows(of: subviews, inWidth: proposal.width ?? .infinity)
        return CGSize(
            width: rows.map(\.width).max() ?? 0,
            height: rows.map(\.height).reduce(0, +) + rowSpacing * CGFloat(max(0, rows.count - 1))
        )
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let rows = rows(of: subviews, inWidth: bounds.width)
        var y = bounds.minY
        for row in rows {
            var x = alignment == .center
                ? bounds.minX + (bounds.width - row.width) / 2
                : bounds.minX
            for index in row.range {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(
                    at: CGPoint(x: x, y: y + row.height / 2),
                    anchor: .leading,
                    proposal: .unspecified
                )
                x += size.width + spacing
            }
            y += row.height + rowSpacing
        }
    }
}
