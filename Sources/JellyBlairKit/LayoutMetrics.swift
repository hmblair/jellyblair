import SwiftUI

/// Every measurement that a regular layout sizes differently from a compact
/// one, grouped by the view it serves. Views read a name from here, so each
/// pair of values has one home and no view repeats the choice.
public struct LayoutMetrics {
    public let bookScreen: BookScreenMetrics
    public let playbackBar: PlaybackBarMetrics
    public let transport: TransportMetrics
    public let pane: PaneMetrics
}

/// The book screen's page padding and header typography.
public struct BookScreenMetrics {
    /// Side padding of the whole page. The compact layout pads its upper
    /// content instead, so its list runs edge to edge.
    public let pageHorizontalPadding: CGFloat
    public let pageTopPadding: CGFloat
    /// Side padding of the header and the play button.
    public let contentHorizontalPadding: CGFloat
    public let coverCornerRadius: CGFloat
    public let coverSpacing: CGFloat
    public let titleFont: Font
    public let lineFont: Font
    public let playButtonControlSize: ControlSize
    /// True where the list below competes for vertical space, which without
    /// this compresses the header's text into truncation instead of wrapping.
    public let headerKeepsIntrinsicHeight: Bool
}

/// The playback bar's arrangement and the size of its info block.
public struct PlaybackBarMetrics {
    /// True for the single row of info, seek cluster and transport. The
    /// compact bar stacks the seek cluster above the other two instead.
    public let usesSingleRow: Bool
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
    /// The font of the seek row's time labels and the speed menu's label,
    /// one notch above a caption in each density.
    public let readoutFont: Font
    public let playButtonSize: CGFloat
    public let skipButtonSize: CGFloat
    public let buttonSpacing: CGFloat
}

/// The book screen's chapter and transcript panes.
public struct PaneMetrics {
    /// Side padding of the transcript text: the compact layout's content
    /// padding, and the inset list's margin when regular.
    public let transcriptHorizontalPadding: CGFloat
    public let searchBarHorizontalPadding: CGFloat
}

public extension LayoutMetrics {
    static let compact = LayoutMetrics(
        bookScreen: BookScreenMetrics(
            pageHorizontalPadding: 0,
            pageTopPadding: 8,
            contentHorizontalPadding: 20,
            coverCornerRadius: 12,
            coverSpacing: 10,
            titleFont: .title2.bold(),
            lineFont: .callout,
            playButtonControlSize: .regular,
            headerKeepsIntrinsicHeight: true
        ),
        playbackBar: PlaybackBarMetrics(
            usesSingleRow: false,
            coverSize: 40,
            titleFont: .callout.weight(.semibold),
            subtitleFont: .caption,
            topPadding: 8,
            bottomPadding: 0
        ),
        transport: TransportMetrics(
            readoutFont: .footnote.monospacedDigit(),
            playButtonSize: 40,
            skipButtonSize: 22,
            buttonSpacing: 16
        ),
        pane: PaneMetrics(
            transcriptHorizontalPadding: 20,
            searchBarHorizontalPadding: 20
        )
    )

    static let regular = LayoutMetrics(
        bookScreen: BookScreenMetrics(
            pageHorizontalPadding: 20,
            pageTopPadding: 20,
            contentHorizontalPadding: 0,
            coverCornerRadius: 10,
            coverSpacing: 12,
            titleFont: .title.bold(),
            lineFont: .title3,
            // The large control is a modest button here but a thick capsule
            // when compact; the regular size matches this look there.
            playButtonControlSize: .large,
            headerKeepsIntrinsicHeight: false
        ),
        playbackBar: PlaybackBarMetrics(
            usesSingleRow: true,
            coverSize: 48,
            titleFont: .body.weight(.semibold),
            subtitleFont: .subheadline,
            topPadding: 10,
            bottomPadding: 10
        ),
        transport: TransportMetrics(
            readoutFont: .subheadline.monospacedDigit(),
            playButtonSize: 34,
            skipButtonSize: 20,
            buttonSpacing: 12
        ),
        pane: PaneMetrics(
            transcriptHorizontalPadding: 12,
            searchBarHorizontalPadding: 0
        )
    )
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
