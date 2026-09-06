import SwiftUI

/// The app-wide playback bar, shown at the bottom whenever a book is
/// loaded. Tapping the info area navigates to the book's screen.
public struct PlaybackBar: View {
    let onOpen: (Book) -> Void

    @Environment(PlayerController.self) private var player
    @Environment(BookCatalog.self) private var catalog

    /// Width cap of the Mac bar's info block; longer names truncate.
    private static let infoMaxWidth: CGFloat = 280

    /// Width cap of the Mac bar's seek cluster, so the bar reads as one
    /// control instead of a line spanning the window. The time labels and
    /// the speed menu take roughly 250 points of it; the rest is the bar.
    private static let seekClusterMaxWidth: CGFloat = 720

    /// The info block's measurements, a step larger on the Mac.
    #if os(macOS)
    private static let coverSize: CGFloat = 48
    private static let titleFont: Font = .body.weight(.semibold)
    private static let subtitleFont: Font = .subheadline
    #else
    private static let coverSize: CGFloat = 40
    private static let titleFont: Font = .callout.weight(.semibold)
    private static let subtitleFont: Font = .caption
    #endif

    public init(onOpen: @escaping (Book) -> Void) {
        self.onOpen = onOpen
    }

    public var body: some View {
        if let book = player.book {
            VStack(spacing: 8) {
                if let message = player.playbackErrorMessage {
                    errorRow(message)
                }
                controls(for: book)
            }
            .padding(.horizontal, 16)
            // The Mac window edge needs clearance below; the phone's safe
            // area already provides it.
            #if os(macOS)
            .padding(.vertical, 10)
            #else
            .padding(.top, 8)
            #endif
            .background(.bar)
            .overlay(alignment: .top) {
                Divider()
            }
        }
    }

    #if os(macOS)
    /// One row: the info at the leading edge, the transport at the trailing
    /// edge, and the seek cluster centered in the space between them. The
    /// bar layout sizes and places each element independently.
    private func controls(for book: Book) -> some View {
        BarLayout(infoMaximum: Self.infoMaxWidth, clusterMaximum: Self.seekClusterMaxWidth, spacing: 16) {
            info(for: book)
            seekCluster
            TransportControlsView()
        }
    }
    #else
    /// Two rows: the seek cluster, then the info with the transport.
    private func controls(for book: Book) -> some View {
        VStack(spacing: 8) {
            seekCluster
            HStack(spacing: 12) {
                info(for: book)
                Spacer(minLength: 12)
                TransportControlsView()
            }
        }
    }
    #endif

    /// The seek bar with the speed menu beside it.
    private var seekCluster: some View {
        HStack(spacing: 8) {
            SeekTimeRow()
            PlaybackSpeedMenu()
        }
    }

    /// The loaded book's cover with the chapter title over the book name,
    /// or the name alone before the chapters are known.
    private func info(for book: Book) -> some View {
        HStack(spacing: 12) {
            BookCoverImage(bookID: book.id, url: catalog.coverURL(for: book), contentMode: .fill)
                .frame(width: Self.coverSize, height: Self.coverSize)
                .clipShape(RoundedRectangle(cornerRadius: 6))
            VStack(alignment: .leading, spacing: 2) {
                Text(player.currentChapter?.title ?? book.name)
                    .font(Self.titleFont)
                    .lineLimit(1)
                if player.currentChapter != nil {
                    Text(book.name)
                        .font(Self.subtitleFont)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            onOpen(book)
        }
    }

    private func errorRow(_ message: String) -> some View {
        HStack {
            Label(message, systemImage: "exclamationmark.triangle")
                .foregroundStyle(.red)
                .lineLimit(1)
            Spacer()
            Button("Retry") {
                player.retryCurrentBook()
            }
        }
    }
}

#if os(macOS)
/// Places the bar's three elements independently of each other: the first
/// at the leading edge, the third at the trailing edge, and the second
/// centered in the space between its two neighbors, each centered
/// vertically. The info hugs its content up to its cap, the transport
/// takes its own size, and the cluster gets all the space they leave, up
/// to its cap.
private struct BarLayout: Layout {
    let infoMaximum: CGFloat
    let clusterMaximum: CGFloat
    let spacing: CGFloat

    /// The bar's three subviews under their names, in declaration order.
    private struct Elements {
        let info: LayoutSubview
        let cluster: LayoutSubview
        let transport: LayoutSubview

        init?(_ subviews: Subviews) {
            guard subviews.count == 3 else { return nil }
            info = subviews[0]
            cluster = subviews[1]
            transport = subviews[2]
        }
    }

    private struct ElementSizes {
        let info: CGSize
        let cluster: CGSize
        let transport: CGSize
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let elements = Elements(subviews) else { return .zero }
        let sizes = sizes(of: elements, inBarWidth: proposal.width)
        let width = proposal.width
            ?? (sizes.info.width + sizes.cluster.width + sizes.transport.width + 2 * spacing)
        let height = max(sizes.info.height, sizes.cluster.height, sizes.transport.height)
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard let elements = Elements(subviews) else { return }
        let sizes = sizes(of: elements, inBarWidth: bounds.width)
        elements.info.place(
            at: CGPoint(x: bounds.minX, y: bounds.midY),
            anchor: .leading,
            proposal: ProposedViewSize(sizes.info)
        )
        // The midpoint of the gap between the info and the transport.
        let clusterX = (bounds.minX + sizes.info.width + bounds.maxX - sizes.transport.width) / 2
        elements.cluster.place(
            at: CGPoint(x: clusterX, y: bounds.midY),
            anchor: .center,
            proposal: ProposedViewSize(sizes.cluster)
        )
        elements.transport.place(
            at: CGPoint(x: bounds.maxX, y: bounds.midY),
            anchor: .trailing,
            proposal: ProposedViewSize(sizes.transport)
        )
    }

    /// The elements' sizes for the given bar width: the info at its content
    /// width up to its cap, the transport at its own size, and the cluster
    /// at the width those two leave between them, up to its cap.
    private func sizes(of elements: Elements, inBarWidth barWidth: CGFloat?) -> ElementSizes {
        let transport = elements.transport.sizeThatFits(.unspecified)
        let infoWidth = min(elements.info.sizeThatFits(.unspecified).width, infoMaximum)
        let available = (barWidth ?? .infinity) - infoWidth - transport.width - 2 * spacing
        let clusterWidth = max(0, min(clusterMaximum, available))
        return ElementSizes(
            info: CGSize(width: infoWidth, height: height(of: elements.info, atWidth: infoWidth)),
            cluster: CGSize(width: clusterWidth, height: height(of: elements.cluster, atWidth: clusterWidth)),
            transport: transport
        )
    }

    /// The element's height when laid out at the given width.
    private func height(of element: LayoutSubview, atWidth width: CGFloat) -> CGFloat {
        element.sizeThatFits(ProposedViewSize(width: width, height: nil)).height
    }
}
#endif
