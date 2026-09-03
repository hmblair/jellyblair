import SwiftUI

/// A transcript line's relationship to the listener's position.
public enum LyricRowState: Equatable {
    case played
    case current
    case upcoming
}

/// One transcript line as a single text view, so every line wraps exactly
/// as native text and realizes cheaply when a scroll crosses many rows.
/// Read characters are grey, the spoken cue's take the accent color, and
/// unread ones keep the primary color. Each cued word's range carries a
/// link, so a click on a word seeks to its cue. On the current line the
/// spoken cue's range carries a renderer attribute whose reported frame
/// places the scroll marker.
public struct LyricLineText: View, Equatable {
    let line: LyricLine
    let state: LyricRowState
    /// True for a line that is a chapter's heading, drawn in a title style.
    let isTitle: Bool
    /// The playback position, set only on the current line.
    let positionSeconds: Double?
    /// Called with the clicked word's cue.
    let onWordTap: ((LyricCue) -> Void)?
    /// Called with the spoken word's vertical center, measured in the
    /// transcript content's coordinate space, so scrolling does not move it.
    /// Words on one wrapped row share the value; it steps when the narration
    /// wraps onto the next row.
    let onSpokenWordMoved: ((CGFloat) -> Void)?

    /// The spoken word's frame in the text's own coordinates, reported by
    /// the renderer. It positions the scroll marker overlay.
    @State private var spokenWordFrame: CGRect?

    static let font = Font.title2

    /// The style of a chapter heading inside the transcript.
    static let titleFont = Font.title.bold()

    /// Space above a chapter heading, separating it from the preceding text.
    private static let titleTopPadding: CGFloat = 12

    /// The scroll id riding on the word being spoken, so tracking can center
    /// on the wrapped line that contains it.
    public static let spokenWordID = "spokenWord"

    /// The coordinate space of the transcript content, for measuring the
    /// spoken word independently of the scroll position.
    public static let contentSpaceName = "transcriptContent"

    /// How long a word takes to fade between its colors.
    private static let colorFadeDuration: TimeInterval = 0.05

    public init(line: LyricLine, state: LyricRowState, isTitle: Bool = false, positionSeconds: Double? = nil, onWordTap: ((LyricCue) -> Void)? = nil, onSpokenWordMoved: ((CGFloat) -> Void)? = nil) {
        self.line = line
        self.state = state
        self.isTitle = isTitle
        self.positionSeconds = positionSeconds
        self.onWordTap = onWordTap
        self.onSpokenWordMoved = onSpokenWordMoved
    }

    public var body: some View {
        Group {
            if line.cues.isEmpty {
                Text(line.text)
                    .foregroundStyle(state == .played ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
                    .animation(.easeOut(duration: Self.colorFadeDuration), value: state)
            } else {
                cuedText
            }
        }
        .font(isTitle ? Self.titleFont : Self.font)
        .padding(.top, isTitle ? Self.titleTopPadding : 0)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The interpolating content transition fades each character between its
    /// colors when the attributed text changes; the string itself never does.
    private var cuedText: some View {
        let attributed = attributedLine
        return text(for: attributed)
            .textRenderer(SpokenWordRenderer(onSpokenWordFrame: reportSpokenWordFrame))
            .contentTransition(.interpolate)
            .animation(.easeOut(duration: Self.colorFadeDuration), value: attributed)
            .environment(\.openURL, OpenURLAction { url in
                if let cue = cue(forLinkURL: url) {
                    onWordTap?(cue)
                }
                return .handled
            })
            .overlay(alignment: .topLeading) {
                spokenWordMarker
            }
    }

    /// The line as one text value. On the current line the spoken cue's
    /// range carries the renderer attribute, split out through text
    /// concatenation, which keeps the whole line a single paragraph.
    private func text(for attributed: AttributedString) -> Text {
        guard state == .current, let spokenCue,
              let range = characterRange(of: spokenCue.startPosition..<spokenCue.endPosition, in: attributed)
        else { return Text(attributed) }
        let before = AttributedString(attributed[attributed.startIndex..<range.lowerBound])
        let spoken = AttributedString(attributed[range])
        let after = AttributedString(attributed[range.upperBound..<attributed.endIndex])
        return Text(before) + Text(spoken).customAttribute(SpokenWordAttribute()) + Text(after)
    }

    /// The invisible view tracking scrolls to, sized and placed onto the
    /// spoken word from the renderer's report.
    @ViewBuilder
    private var spokenWordMarker: some View {
        if state == .current, let frame = spokenWordFrame {
            // Padding, not offset, moves the marker onto the word: offset
            // shifts only the drawing, so measured frames would stay put.
            Color.clear
                .frame(width: frame.width, height: frame.height)
                .id(Self.spokenWordID)
                .onGeometryChange(for: CGFloat.self) { proxy in
                    proxy.frame(in: .named(Self.contentSpaceName)).midY
                } action: { midY in
                    onSpokenWordMoved?(midY)
                }
                .padding(.leading, frame.minX)
                .padding(.top, frame.minY)
        }
    }

    /// Stores the renderer's report outside the draw pass, only when it
    /// moved the frame.
    private func reportSpokenWordFrame(_ frame: CGRect?) {
        Task { @MainActor in
            if spokenWordFrame != frame {
                spokenWordFrame = frame
            }
        }
    }

    /// Colors the line by each character's place relative to the spoken cue
    /// and puts a link naming its cue on each cued word. The explicit color
    /// on every range keeps link styling out.
    private var attributedLine: AttributedString {
        var attributed = AttributedString(line.text)
        switch state {
        case .played:
            attributed.foregroundColor = .secondary
        case .upcoming:
            attributed.foregroundColor = .primary
        case .current:
            attributed.foregroundColor = .primary
            if let spokenCue {
                if let read = characterRange(of: 0..<spokenCue.startPosition, in: attributed) {
                    attributed[read].foregroundColor = .secondary
                }
                if let spoken = characterRange(of: spokenCue.startPosition..<spokenCue.endPosition, in: attributed) {
                    attributed[spoken].foregroundColor = Color.accentColor
                }
            }
        }
        for token in tokens {
            guard let index = cueIndex(for: token),
                  let range = characterRange(of: token.id..<token.endPosition, in: attributed)
            else { continue }
            attributed[range].link = URL(string: "cue://\(index)")
        }
        return attributed
    }

    /// The index of the cue a click on the word seeks to: the first one it
    /// overlaps.
    private func cueIndex(for token: WordToken) -> Int? {
        line.cues.firstIndex(where: { $0.endPosition > token.id && $0.startPosition < token.endPosition })
    }

    /// The cue named by a link from the line's attributed text.
    private func cue(forLinkURL url: URL) -> LyricCue? {
        guard let host = url.host(), let index = Int(host), line.cues.indices.contains(index) else { return nil }
        return line.cues[index]
    }

    /// The word spoken at the position. During a gap between cues the word
    /// last spoken stays marked, so the mark never blinks off.
    private var spokenCue: LyricCue? {
        guard let positionSeconds else { return nil }
        return line.cues.last(where: { $0.startSeconds <= positionSeconds })
    }

    /// Maps a character range of the line into the attributed text, clamped
    /// to its extent.
    private func characterRange(of lineRange: Range<Int>, in attributed: AttributedString) -> Range<AttributedString.Index>? {
        let start = max(lineRange.lowerBound, 0)
        let end = min(lineRange.upperBound, attributed.characters.count)
        guard end > start else { return nil }
        let lower = attributed.index(attributed.startIndex, offsetByCharacters: start)
        let upper = attributed.index(lower, offsetByCharacters: end - start)
        return lower..<upper
    }

    /// A whitespace-delimited word with its trailing whitespace, identified
    /// by its character position in the line.
    private struct WordToken: Identifiable {
        let id: Int
        let text: String

        var endPosition: Int { id + text.count }
    }

    /// Equality covers everything the rendering reads, so a tick only
    /// re-renders the lines whose inputs moved: the current line each time,
    /// any other line only when its state flips. The two closures carry no
    /// rendered state and stay out of the comparison.
    public static func == (lhs: LyricLineText, rhs: LyricLineText) -> Bool {
        lhs.line == rhs.line && lhs.state == rhs.state && lhs.isTitle == rhs.isTitle && lhs.positionSeconds == rhs.positionSeconds
    }

    /// Splits the line after each run of whitespace, keeping every character,
    /// so the words concatenate back to the exact text.
    private var tokens: [WordToken] {
        let characters = Array(line.text)
        var result: [WordToken] = []
        var start = 0
        var index = 0
        while index < characters.count {
            while index < characters.count, !characters[index].isWhitespace { index += 1 }
            while index < characters.count, characters[index].isWhitespace { index += 1 }
            result.append(WordToken(id: start, text: String(characters[start..<index])))
            start = index
        }
        return result
    }
}

/// Marks the spoken cue's range for the renderer.
private struct SpokenWordAttribute: TextAttribute {}

/// Draws the text unchanged and reports the frame of the range carrying the
/// spoken word attribute, in the text's own coordinates.
private struct SpokenWordRenderer: TextRenderer {
    let onSpokenWordFrame: (CGRect?) -> Void

    func draw(layout: Text.Layout, in context: inout GraphicsContext) {
        for line in layout {
            context.draw(line)
        }
        onSpokenWordFrame(spokenWordFrame(in: layout))
    }

    /// The union of the marked slices' bounds, or nil when none are marked.
    private func spokenWordFrame(in layout: Text.Layout) -> CGRect? {
        var frame: CGRect?
        for line in layout {
            for run in line {
                for slice in run where slice[SpokenWordAttribute.self] != nil {
                    let rect = slice.typographicBounds.rect
                    frame = frame.map { $0.union(rect) } ?? rect
                }
            }
        }
        return frame
    }
}
