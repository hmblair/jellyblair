import SwiftUI

/// Attaches the sleep timer item as a context menu on a chapter row. A
/// right click on the Mac and a long press on the phone open it. The item
/// acts only on the loaded book's chapters.
struct SleepTimerContextMenu: ViewModifier {
    let chapter: Chapter
    let isLoaded: Bool

    func body(content: Content) -> some View {
        content
            .contextMenu {
                SleepTimerMenuItem(chapter: chapter, isLoaded: isLoaded)
            }
    }
}

extension View {
    /// Gives a chapter row the sleep timer item as its context menu.
    func sleepTimerContextMenu(for chapter: Chapter, isLoaded: Bool) -> some View {
        modifier(SleepTimerContextMenu(chapter: chapter, isLoaded: isLoaded))
    }
}

/// One menu item that sets the sleep timer at the chapter's end, or
/// cancels the timer when it already sits there.
struct SleepTimerMenuItem: View {
    let chapter: Chapter
    let isLoaded: Bool

    @Environment(PlayerController.self) private var player

    var body: some View {
        if isLoaded, player.sleepsAfter(chapter) {
            cancelItem
        } else {
            setItem
        }
    }

    private var setItem: some View {
        Button {
            player.setSleepAfter(chapter)
        } label: {
            Label {
                Text("Sleep After This Chapter")
            } icon: {
                sleepTimerIcon.plain
            }
        }
        .disabled(!isLoaded || !player.canSleepAfter(chapter))
    }

    private var cancelItem: some View {
        Button {
            player.cancelSleepTimer()
        } label: {
            Label {
                Text("Cancel Sleep Timer")
            } icon: {
                cancelSleepTimerIcon.plain
            }
        }
    }
}

/// Space between the readouts centered under the seek bar: the remaining
/// time and the sleep readout.
let readoutSpacing: CGFloat = 12

/// The moon glyph with the listening time until the sleep timer fires at
/// the current speed, in the readout style of the remaining time beside
/// it. Hidden while no timer is set. A tap cancels the timer. While the
/// user scrubs, it reads from the scrub position instead.
public struct SleepTimerReadout: View {
    @Environment(PlayerController.self) private var player
    @Environment(\.scrubPosition) private var scrubPosition

    public init() {}

    public var body: some View {
        if player.sleepAtSeconds != nil {
            // Inherits the font from its context, like the readouts beside it.
            TimelineView(.periodic(from: .now, by: 1.0)) { context in
                Button(action: player.cancelSleepTimer) {
                    label(at: context.date)
                }
                .buttonStyle(.plain)
                .hoverDim()
                .help("Cancel the sleep timer")
            }
        }
    }

    private func label(at date: Date) -> some View {
        let position = scrubPosition ?? player.projectedTime(at: date)
        return HStack(spacing: 4) {
            sleepTimerIcon.plain
            Text(formatHoursMinutes(player.secondsUntilSleep(from: position) ?? 0))
                .monospacedDigit()
        }
        .foregroundStyle(.secondary)
    }
}
