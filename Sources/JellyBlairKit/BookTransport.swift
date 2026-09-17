import SwiftUI

/// The loaded book's transport cluster: the playing chapter's title, the
/// seek bar with the times and the remaining listening time, and the
/// transport buttons with the speed menu. Only the loaded book's screen
/// shows it; any other book's screen offers a play button instead, so a
/// transport on screen always means live playback state.
struct BookTransport: View {
    @Environment(PlayerController.self) private var player

    @Environment(\.layoutMetrics) private var metrics

    var body: some View {
        VStack(spacing: 12) {
            chapterLine
            SeekTimeRow(sizes: metrics.playerTransport) {
                HStack(spacing: readoutSpacing) {
                    RemainingTimeView()
                    SleepTimerReadout()
                }
                .font(metrics.playerTransport.readoutFont)
            }
            TransportControlsView(sizes: metrics.playerTransport)
                .frame(maxWidth: .infinity)
                .overlay(alignment: .trailing) {
                    PlaybackSpeedMenu(font: metrics.playerTransport.readoutFont)
                }
        }
    }

    /// The playing chapter's title. On the compact screen, where the
    /// chapter list hides in a sheet, this is the only running chapter
    /// readout.
    @ViewBuilder
    private var chapterLine: some View {
        if let title = player.currentChapter?.title {
            Text(title)
                .font(metrics.bookScreen.lineFont)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }
}
