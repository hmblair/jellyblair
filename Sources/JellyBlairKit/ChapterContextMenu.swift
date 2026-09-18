import SwiftUI

/// Attaches the chapter items as a context menu on a chapter row. A right
/// click on the Mac and a long press on the phone open it. The current
/// chapter's row also offers to resume the book.
struct ChapterContextMenu: ViewModifier {
    let book: Book
    let chapter: Chapter
    let isCurrent: Bool
    let isLoaded: Bool
    let canStartPlayback: Bool

    func body(content: Content) -> some View {
        content
            .contextMenu {
                if isCurrent {
                    ResumeMenuItem(book: book, isLoaded: isLoaded, canStartPlayback: canStartPlayback)
                }
                SleepTimerMenuItem(chapter: chapter, isLoaded: isLoaded)
            }
    }
}

extension View {
    /// Gives a chapter row the chapter items as its context menu.
    func chapterContextMenu(for chapter: Chapter, in book: Book, isCurrent: Bool, isLoaded: Bool, canStartPlayback: Bool) -> some View {
        modifier(ChapterContextMenu(book: book, chapter: chapter, isCurrent: isCurrent, isLoaded: isLoaded, canStartPlayback: canStartPlayback))
    }
}

/// One menu item that continues the book from its current position. A
/// loaded book plays from where it stands; a preview opens the book at
/// its resume position.
struct ResumeMenuItem: View {
    let book: Book
    let isLoaded: Bool
    let canStartPlayback: Bool

    @Environment(PlayerController.self) private var player

    var body: some View {
        Button {
            resume()
        } label: {
            Label {
                Text("Resume")
            } icon: {
                playIcon.plain
            }
        }
        .disabled(!canResume)
    }

    private var canResume: Bool {
        isLoaded ? !player.isPlaying : canStartPlayback
    }

    private func resume() {
        if isLoaded {
            player.play()
        } else {
            player.open(book, playWhenReady: true)
        }
    }
}
