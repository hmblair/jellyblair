import SwiftUI

/// The app-wide playback bar, shown at the bottom whenever a book is
/// loaded: the controls in a rounded glass container that floats inside
/// the window's edges. Tapping the info area navigates to the book's
/// screen.
public struct PlaybackBar: View {
    let onOpen: (Book) -> Void

    @Environment(PlayerController.self) private var player
    @Environment(\.layoutMetrics) private var metrics

    /// Width cap of the single-row bar's seek cluster, so the bar reads as
    /// one control instead of a line spanning the window.
    private static let seekClusterMaxWidth: CGFloat = 720

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
            .padding(.horizontal, metrics.playbackBar.horizontalPadding)
            .padding(.vertical, metrics.playbackBar.verticalPadding)
            .glassEffect(.regular, in: RoundedRectangle(cornerRadius: metrics.playbackBar.cornerRadius))
            .padding(metrics.playbackBar.margin)
        }
    }

    @ViewBuilder
    private func controls(for book: Book) -> some View {
        if metrics.playbackBar.showsSeekCluster {
            seekClusterControls(for: book)
        } else {
            infoTransportControls(for: book)
        }
    }

    /// The info at the leading edge, the transport at the trailing edge,
    /// and the seek cluster centered on the bar itself. The bar layout
    /// sizes and places each element independently.
    private func seekClusterControls(for book: Book) -> some View {
        BarLayout(clusterMaximum: Self.seekClusterMaxWidth, spacing: 32) {
            info(for: book)
            seekCluster
            transportWithSpeed
        }
    }

    /// The info with the transport. This bar carries neither the seek
    /// cluster nor the speed menu; the book screen's own transport does
    /// both.
    private func infoTransportControls(for book: Book) -> some View {
        HStack(spacing: 12) {
            info(for: book)
            Spacer(minLength: 12)
            TransportControlsView(layout: metrics.playbackBar.transportLayout)
        }
    }

    /// The seek bar in the player layout: the times under the bar's ends
    /// with the remaining time between them.
    private var seekCluster: some View {
        SeekTimeRow {
            RemainingTimeView()
                .font(metrics.transport.readoutFont)
        }
    }

    /// The transport with the speed menu leading its skip-back button,
    /// centered like the buttons.
    private var transportWithSpeed: some View {
        HStack(spacing: metrics.transport.buttonSpacing) {
            PlaybackSpeedMenu()
            TransportControlsView(layout: metrics.playbackBar.transportLayout)
        }
    }

    /// The loaded book's cover with the chapter title over the book title,
    /// or the book title alone before the chapters are known. The bar is
    /// width-bound, so both titles leave out their subtitles.
    private func info(for book: Book) -> some View {
        HStack(spacing: 12) {
            BookCoverImage(bookID: book.id, url: book.coverURL, contentMode: .fill)
                .frame(width: metrics.playbackBar.coverSize, height: metrics.playbackBar.coverSize)
                .clipShape(RoundedRectangle(cornerRadius: 6))
            VStack(alignment: .leading, spacing: 2) {
                Text(player.currentChapter?.mainTitle ?? book.mainTitle)
                    .font(metrics.playbackBar.titleFont)
                    .lineLimit(1)
                if player.currentChapter != nil {
                    Text(book.mainTitle)
                        .font(metrics.playbackBar.subtitleFont)
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

/// Places the bar's three elements independently of each other, each
/// centered vertically: the info at the leading edge, the transport at
/// the trailing edge, and the cluster centered on the bar itself — not in
/// the gap between its neighbors — so the two sides keep an even balance.
/// The transport takes its own size; the cluster spans twice the distance
/// from the bar's center to the transport's spacing, up to its cap; and
/// the info truncates into the space the cluster's leading edge leaves.
private struct BarLayout: Layout {
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
        elements.cluster.place(
            at: CGPoint(x: bounds.midX, y: bounds.midY),
            anchor: .center,
            proposal: ProposedViewSize(sizes.cluster)
        )
        elements.transport.place(
            at: CGPoint(x: bounds.maxX, y: bounds.midY),
            anchor: .trailing,
            proposal: ProposedViewSize(sizes.transport)
        )
    }

    /// The elements' sizes for the given bar width: the transport at its
    /// own size, the centered cluster at twice the center-to-transport
    /// distance up to its cap, and the info truncating into the space up
    /// to the cluster's leading edge.
    private func sizes(of elements: Elements, inBarWidth barWidth: CGFloat?) -> ElementSizes {
        let transport = elements.transport.sizeThatFits(.unspecified)
        let infoIdeal = elements.info.sizeThatFits(.unspecified).width
        guard let barWidth else {
            return ElementSizes(
                info: CGSize(width: infoIdeal, height: height(of: elements.info, atWidth: infoIdeal)),
                cluster: CGSize(width: clusterMaximum, height: height(of: elements.cluster, atWidth: clusterMaximum)),
                transport: transport
            )
        }
        let clusterWidth = max(0, min(clusterMaximum, barWidth - 2 * (transport.width + spacing)))
        let infoWidth = max(0, min(infoIdeal, (barWidth - clusterWidth) / 2 - spacing))
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
