import SwiftUI

/// Every measurement that a regular layout sizes differently from a compact
/// one, grouped by the view it serves. Views read a name from here, so each
/// pair of values has one home and no view repeats the choice.
public struct LayoutMetrics {
    public let bookScreen: BookScreenMetrics
    public let playbackBar: PlaybackBarMetrics
    /// The playback bar's transport sizes.
    public let transport: TransportMetrics
    /// The player screen's transport sizes, larger than the bar's.
    public let playerTransport: TransportMetrics
    public let pane: PaneMetrics
}

/// The book screen's page padding and player header measurements.
public struct BookScreenMetrics {
    /// Side padding of the whole page. The compact layout pads its upper
    /// content instead, so its list runs edge to edge.
    public let pageHorizontalPadding: CGFloat
    public let pageTopPadding: CGFloat
    /// Clearance under the page's last element.
    public let pageBottomPadding: CGFloat
    /// Side padding of the player header.
    public let contentHorizontalPadding: CGFloat
    public let coverCornerRadius: CGFloat
    /// The side of the player header's square cover.
    public let playerCoverSize: CGFloat
    public let titleFont: Font
    public let lineFont: Font
    /// The font of the header's quietest line, the publisher and year.
    public let detailFont: Font
    public let playButtonControlSize: ControlSize
}

/// The playback bar's arrangement and the size of its info block.
public struct PlaybackBarMetrics {
    /// True where the bar has the width for the seek cluster between the
    /// info and the transport. The compact bar leaves seeking to the book
    /// screen's own transport.
    public let showsSeekCluster: Bool
    public let coverSize: CGFloat
    public let titleFont: Font
    public let subtitleFont: Font
    public let topPadding: CGFloat
    /// The Mac window edge needs clearance below. The phone's safe area
    /// already provides it.
    public let bottomPadding: CGFloat
}

/// The transport controls' button sizes and readout font.
public struct TransportMetrics {
    /// The font of the seek row's time labels and the speed menu's label.
    public let readoutFont: Font
    public let playButtonSize: CGFloat
    public let skipButtonSize: CGFloat
    public let buttonSpacing: CGFloat

    /// The same buttons at a larger size with the readout unchanged. The
    /// shared gaps between the buttons also stay, unless the caller sets
    /// its own spacing.
    func scaled(by factor: CGFloat, spacing: CGFloat? = nil) -> TransportMetrics {
        TransportMetrics(
            readoutFont: readoutFont,
            playButtonSize: playButtonSize * factor,
            skipButtonSize: skipButtonSize * factor,
            buttonSpacing: spacing ?? buttonSpacing
        )
    }
}

/// What a pane draws behind its rows.
public enum PaneBackdrop {
    /// Nothing: the cover wash runs behind the rows to the screen edges.
    case clear
    /// A rounded glass card floating in the page.
    case card
}

/// The book screen's chapter and transcript panes.
public struct PaneMetrics {
    /// Side padding of the transcript text: the compact layout's content
    /// padding, and a margin within the pane card when regular.
    public let transcriptHorizontalPadding: CGFloat
    public let searchBarHorizontalPadding: CGFloat
    /// Width cap of the panes. A regular layout is far wider than a readable
    /// row, so the panes hold a centered column; a compact one fills the
    /// screen.
    public let maxWidth: CGFloat
    public let backdrop: PaneBackdrop
}

/// The regular cover's side: larger on the iPad, whose text styles run
/// about a quarter larger than the Mac's, so the cover keeps the same
/// proportion to the text on both.
private var regularPlayerCoverSize: CGFloat {
    #if os(macOS)
    return 240
    #else
    return 300
    #endif
}

/// The regular play button's control size: modest on the Mac, where the
/// large control is a normal button, and regular on the iPad, where the
/// large control is a thick capsule.
private var regularPlayButtonControlSize: ControlSize {
    #if os(macOS)
    return .large
    #else
    return .regular
    #endif
}

public extension LayoutMetrics {
    static let compact: LayoutMetrics = {
        let baseTransport = TransportMetrics(
            readoutFont: .subheadline.monospacedDigit(),
            playButtonSize: 40,
            skipButtonSize: 22,
            buttonSpacing: 12
        )
        return LayoutMetrics(
            bookScreen: BookScreenMetrics(
                pageHorizontalPadding: 0,
                pageTopPadding: 8,
                pageBottomPadding: 12,
                contentHorizontalPadding: 20,
                coverCornerRadius: 12,
                playerCoverSize: 280,
                titleFont: .title2.bold(),
                lineFont: .callout,
                detailFont: .footnote,
                // The large control is a thick capsule here; the regular
                // size matches the large control's modest look elsewhere.
                playButtonControlSize: .regular
            ),
            playbackBar: PlaybackBarMetrics(
                showsSeekCluster: false,
                coverSize: 40,
                titleFont: .callout.weight(.semibold),
                subtitleFont: .caption,
                topPadding: 8,
                bottomPadding: 0
            ),
            transport: baseTransport.scaled(by: 1.25),
            // The player screen's buttons spread wider than the bars',
            // matching their larger size.
            playerTransport: baseTransport.scaled(by: 1.5, spacing: 24),
            pane: PaneMetrics(
                transcriptHorizontalPadding: 20,
                searchBarHorizontalPadding: 20,
                maxWidth: .infinity,
                backdrop: .clear
            )
        )
    }()

    static let regular: LayoutMetrics = {
        let baseTransport = TransportMetrics(
            readoutFont: .subheadline.monospacedDigit(),
            playButtonSize: 34,
            skipButtonSize: 20,
            buttonSpacing: 12
        )
        // The iPad's transport buttons are touch targets, so they run a
        // quarter larger than the Mac's pointer-sized ones.
        #if os(macOS)
        let transport = baseTransport
        #else
        let transport = baseTransport.scaled(by: 1.25)
        #endif
        return LayoutMetrics(
            bookScreen: BookScreenMetrics(
                pageHorizontalPadding: 20,
                pageTopPadding: 20,
                pageBottomPadding: 20,
                contentHorizontalPadding: 0,
                coverCornerRadius: 10,
                playerCoverSize: regularPlayerCoverSize,
                titleFont: .title.bold(),
                lineFont: .body,
                detailFont: .callout,
                playButtonControlSize: regularPlayButtonControlSize
            ),
            playbackBar: PlaybackBarMetrics(
                showsSeekCluster: true,
                coverSize: 48,
                titleFont: .body.weight(.semibold),
                subtitleFont: .subheadline,
                topPadding: 10,
                bottomPadding: 10
            ),
            transport: transport,
            playerTransport: transport.scaled(by: 1.25),
            pane: PaneMetrics(
                transcriptHorizontalPadding: 12,
                searchBarHorizontalPadding: 12,
                maxWidth: 680,
                backdrop: .card
            )
        )
    }()
}

public extension LayoutDensity {
    /// The measurements of this density.
    var metrics: LayoutMetrics {
        switch self {
        case .compact: return .compact
        case .regular: return .regular
        }
    }
}
