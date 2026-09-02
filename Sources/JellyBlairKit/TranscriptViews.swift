import SwiftUI

/// A transcript line's relationship to the listener's position.
public enum LyricRowState: Equatable {
    case played
    case current
    case upcoming
}

/// One transcript line as flowing text, one view per whitespace-delimited
/// word so each word can be clicked on its own. Every word keeps its original
/// trailing whitespace and the layout adds none, so the line's spacing is
/// exactly the text's. Read words are grey, the word being spoken at the
/// given position takes the accent color, and unread words keep the primary
/// color; a word spanning several cues, like an em-dashed pair, colors each
/// cued part on its own inside the one view.
public struct LyricLineText: View, Equatable {
    let line: LyricLine
    let state: LyricRowState
    /// The playback position, set only on the current line.
    let positionSeconds: Double?
    /// Called with the clicked word's cue.
    let onWordTap: ((LyricCue) -> Void)?
    /// Called with the spoken word's vertical center, measured in the
    /// transcript content's coordinate space, so scrolling does not move it.
    /// Words on one wrapped row share the value; it steps when the narration
    /// wraps onto the next row.
    let onSpokenWordMoved: ((CGFloat) -> Void)?

    static let font = Font.title3

    /// The scroll id riding on the word being spoken, so tracking can center
    /// on the wrapped line that contains it.
    public static let spokenWordID = "spokenWord"

    /// The coordinate space of the transcript content, for measuring the
    /// spoken word independently of the scroll position.
    public static let contentSpaceName = "transcriptContent"

    /// How long a word takes to fade between its colors.
    private static let colorFadeDuration: TimeInterval = 0.05

    public init(line: LyricLine, state: LyricRowState, positionSeconds: Double? = nil, onWordTap: ((LyricCue) -> Void)? = nil, onSpokenWordMoved: ((CGFloat) -> Void)? = nil) {
        self.line = line
        self.state = state
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
                FlowLayout(alignment: .leading, horizontalSpacing: 0) {
                    ForEach(tokens) { token in
                        tokenView(token)
                    }
                }
            }
        }
        .font(Self.font)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The interpolating content transition fades each character between its
    /// colors when the attributed text changes; the string itself never does.
    /// The spoken word carries the scroll marker on an invisible background,
    /// so the word's own identity, and with it the fade, stays stable.
    @ViewBuilder
    private func tokenView(_ token: WordToken) -> some View {
        let attributed = attributedText(for: token)
        let text = Text(attributed)
            .contentTransition(.interpolate)
            .animation(.easeOut(duration: Self.colorFadeDuration), value: attributed)
            .background {
                if isSpoken(token) {
                    Color.clear
                        .id(Self.spokenWordID)
                        .onGeometryChange(for: CGFloat.self) { proxy in
                            proxy.frame(in: .named(Self.contentSpaceName)).midY
                        } action: { midY in
                            onSpokenWordMoved?(midY)
                        }
                }
            }
        if let cue = cue(for: token), let onWordTap {
            text.onTapGesture {
                onWordTap(cue)
            }
        } else {
            text
        }
    }

    /// True when the token holds the word being spoken.
    private func isSpoken(_ token: WordToken) -> Bool {
        guard let spokenCue else { return false }
        return spokenCue.startPosition >= token.id && spokenCue.startPosition < token.endPosition
    }

    /// The cue a click on the word seeks to: the first one it overlaps.
    private func cue(for token: WordToken) -> LyricCue? {
        line.cues.first(where: { $0.endPosition > token.id && $0.startPosition < token.endPosition })
    }

    /// The word spoken at the position. During a gap between cues the word
    /// last spoken stays marked, so the mark never blinks off.
    private var spokenCue: LyricCue? {
        guard let positionSeconds else { return nil }
        return line.cues.last(where: { $0.startSeconds <= positionSeconds })
    }

    /// Colors the word's text by each character's place relative to the
    /// spoken cue: read characters grey, the spoken cue's the accent color,
    /// unread ones the primary color.
    private func attributedText(for token: WordToken) -> AttributedString {
        var attributed = AttributedString(token.text)
        switch state {
        case .played:
            attributed.foregroundColor = .secondary
        case .upcoming:
            attributed.foregroundColor = .primary
        case .current:
            guard let spokenCue else {
                attributed.foregroundColor = .primary
                return attributed
            }
            attributed.foregroundColor = .primary
            if let read = localRange(of: 0..<spokenCue.startPosition, in: attributed, token: token) {
                attributed[read].foregroundColor = .secondary
            }
            if let spoken = localRange(of: spokenCue.startPosition..<spokenCue.endPosition, in: attributed, token: token) {
                attributed[spoken].foregroundColor = Color.accentColor
            }
        }
        return attributed
    }

    /// Maps a character range of the whole line into the token's text,
    /// clamped to their overlap.
    private func localRange(of lineRange: Range<Int>, in attributed: AttributedString, token: WordToken) -> Range<AttributedString.Index>? {
        let start = max(lineRange.lowerBound, token.id) - token.id
        let end = min(lineRange.upperBound, token.endPosition) - token.id
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
        lhs.line == rhs.line && lhs.state == rhs.state && lhs.positionSeconds == rhs.positionSeconds
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
