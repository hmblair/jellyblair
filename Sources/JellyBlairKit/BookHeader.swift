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
                playIcon.plain
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
                let remaining = formatHoursMinutes(book.remainingSeconds)
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

/// The title block as three groups — the title with its subtitle, the
/// credit lines with the series line, and one catalog line — spaced apart
/// so each reads at a glance. The lines wrap, following the given
/// alignment.
struct BookTitleBlock: View {
    let book: Book
    let alignment: HorizontalAlignment

    @Environment(\.openBookGroup) private var openBookGroup
    @Environment(\.layoutMetrics) private var metrics

    /// The space between the three groups, wider than the space inside
    /// them, so the block reads as three units.
    private static let groupSpacing: CGFloat = 12

    var body: some View {
        VStack(alignment: alignment, spacing: Self.groupSpacing) {
            titleGroup
            creditsGroup
            catalogLine
        }
        .multilineTextAlignment(alignment == .center ? .center : .leading)
    }

    /// The title tight over its subtitle, the subtitle one step smaller
    /// and dimmer. A title with no colon shows one line.
    private var titleGroup: some View {
        VStack(alignment: alignment, spacing: 2) {
            Text(book.mainTitle)
                .font(metrics.bookScreen.titleFont)
            if let subtitle = book.subtitle {
                Text(subtitle)
                    .font(metrics.bookScreen.subtitleFont)
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// One credit line per group of roles naming the same people, from
    /// "Written by" through "Written, translated, and read by", then the
    /// series line. Every person's name opens the person's shelf,
    /// whichever roles it holds.
    @ViewBuilder
    private var creditsGroup: some View {
        if !book.credits.isEmpty || book.series != nil {
            VStack(alignment: alignment, spacing: 3) {
                ForEach(book.credits, id: \.self) { credit in
                    creditLine(prefix: credit.roles.creditPrefix, names: credit.names)
                }
                if let series = book.series {
                    seriesLine(series)
                }
            }
            .font(metrics.bookScreen.lineFont)
            .foregroundStyle(.secondary)
        }
    }

    /// One line reading "Part of the x series", with the name opening the
    /// shelf of the series.
    private func seriesLine(_ series: String) -> some View {
        FlowLine(alignment: alignment) {
            Text("Part of the")
            GroupNameButton(kind: .series, name: series, open: openBookGroup)
            Text("series")
        }
    }

    /// One line reading "Prefix x", "Prefix x and y", or "Prefix x, y,
    /// and z", with each name its own hover-and-click target. The words
    /// flow and wrap like text; a comma lives with the name before it,
    /// so a wrap never strands one.
    private func creditLine(prefix: String, names: [String]) -> some View {
        FlowLine(alignment: alignment) {
            Text(verbatim: prefix)
            ForEach(Array(names.enumerated()), id: \.offset) { index, name in
                HStack(spacing: 0) {
                    GroupNameButton(kind: .person, name: name, open: openBookGroup)
                    if names.count > 2, index < names.count - 1 {
                        Text(verbatim: ",")
                    }
                }
                if index == names.count - 2 {
                    Text("and")
                }
            }
        }
    }

    /// The publisher names, the year, and the genres joined by dots on
    /// one line, the block's quietest. Publisher and genre names open
    /// their shelves; dots instead of commas, since the entries read as
    /// tags rather than a sentence. A dot lives with the entry before
    /// it, so a wrap never strands one.
    @ViewBuilder
    private var catalogLine: some View {
        let entries = catalogEntries
        if !entries.isEmpty {
            FlowLine(alignment: alignment) {
                ForEach(Array(entries.enumerated()), id: \.offset) { index, entry in
                    HStack(spacing: 4) {
                        if let kind = entry.kind {
                            GroupNameButton(kind: kind, name: entry.text, open: openBookGroup)
                        } else {
                            Text(verbatim: entry.text)
                        }
                        if index < entries.count - 1 {
                            Text(verbatim: "·")
                        }
                    }
                }
            }
            .font(metrics.bookScreen.detailFont)
            .foregroundStyle(.tertiary)
        }
    }

    /// The catalog line's entries in order: publishers, the year, then
    /// genres. Each entry carries the shelf kind it opens, or none for
    /// the year.
    private var catalogEntries: [(kind: BookGroup.Kind?, text: String)] {
        var entries: [(kind: BookGroup.Kind?, text: String)] = []
        entries += BookGroup.Kind.publisher.names(of: book).map { (.publisher, $0) }
        if let year = book.productionYear {
            entries.append((nil, String(year)))
        }
        entries += BookGroup.Kind.genre.names(of: book).map { (.genre, $0) }
        return entries
    }
}

/// One name as its own hover-and-click target, navigating to the name's
/// books when the shell provides a destination.
private struct GroupNameButton: View {
    let kind: BookGroup.Kind
    let name: String
    let open: OpenBookGroupAction?

    var body: some View {
        if let open {
            Button {
                open(kind, name)
            } label: {
                Text(name)
            }
            .buttonStyle(.plain)
            .hoverDim()
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
