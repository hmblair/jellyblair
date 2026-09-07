import Foundation
#if canImport(AppKit)
import AppKit
#else
import UIKit
#endif

/// What a click on the transcript hits: a chapter heading, or a word with
/// a cue.
enum TranscriptTapTarget {
    case chapter(Chapter)
    case word(LyricCue)
}

/// The text styles, from the platform's semantic fonts and colors so the
/// view follows the system appearance.
enum TranscriptStyle {
    static let body: PlatformFont = .preferredFont(forTextStyle: .title2)
    static let title: PlatformFont = {
        let base = PlatformFont.preferredFont(forTextStyle: .title1)
        #if canImport(AppKit)
        return NSFontManager.shared.convert(base, toHaveTrait: .boldFontMask)
        #else
        guard let descriptor = base.fontDescriptor.withSymbolicTraits(.traitBold) else { return base }
        return UIFont(descriptor: descriptor, size: 0)
        #endif
    }()
    static let read: PlatformColor = .secondaryLabel
    static let unread: PlatformColor = .label
    static let spoken: PlatformColor = .accent
    static let match: PlatformColor = .matchHighlight

    static let paragraph: NSParagraphStyle = {
        let style = NSMutableParagraphStyle()
        style.paragraphSpacing = 4
        return style
    }()

    static let titleParagraph: NSParagraphStyle = {
        let style = NSMutableParagraphStyle()
        style.paragraphSpacing = 4
        style.paragraphSpacingBefore = 12
        return style
    }()

    static let bodyAttributes: [NSAttributedString.Key: Any] = [
        .font: body,
        .foregroundColor: unread,
        .paragraphStyle: paragraph,
    ]

    static let titleAttributes: [NSAttributedString.Key: Any] = [
        .font: title,
        .foregroundColor: unread,
        .paragraphStyle: titleParagraph,
    ]
}

/// The transcript's text model, derived once from the lines and chapters:
/// the display lines with chapter headings merged in, the storage range of
/// each line, the timing index, and the built attributed string. A pure
/// value; every question about the text — which line a position is in,
/// where a cue sits in the storage, what a click hits — is answered here
/// without touching the view.
struct TranscriptContent {
    /// The lines as given, kept for change detection.
    let sourceLines: [LyricLine]
    let chapters: [Chapter]
    /// The lines on display: the source lines with one heading line per
    /// chapter.
    let lines: [LyricLine]
    /// The chapter behind each heading line, keyed by the line's position
    /// in the display lines.
    let titleChapters: [Int: Chapter]
    /// UTF-16 range of each line's text inside the storage.
    let lineRanges: [NSRange]
    /// Start times of the timed lines with their array positions, in
    /// order, for binary-searching the current line.
    let timedLines: [(start: Double, position: Int)]
    /// The storage's content: one paragraph per line, headings in the
    /// title style, everything in the unread color. Final colors come from
    /// the color resolver, not from the storage.
    let attributedString: NSAttributedString

    /// The plain text, for background searching.
    var plainText: String { attributedString.string }

    init(sourceLines: [LyricLine], chapters: [Chapter]) {
        self.sourceLines = sourceLines
        self.chapters = chapters
        (lines, titleChapters) = Self.mergedLines(sourceLines, chapters: chapters)
        var lineRanges: [NSRange] = []
        var timedLines: [(start: Double, position: Int)] = []
        let content = NSMutableAttributedString()
        for (position, line) in lines.enumerated() {
            let isTitle = titleChapters[position] != nil
            let attributes = isTitle ? TranscriptStyle.titleAttributes : TranscriptStyle.bodyAttributes
            let text = NSAttributedString(string: line.text + "\n", attributes: attributes)
            lineRanges.append(NSRange(location: content.length, length: (line.text as NSString).length))
            if let start = line.startSeconds {
                timedLines.append((start: start, position: position))
            }
            content.append(text)
        }
        self.lineRanges = lineRanges
        self.timedLines = timedLines
        self.attributedString = content
    }

    // MARK: - Merging

    /// Builds the display lines: the source lines with one heading line per
    /// chapter. The transcript line at the chapter's start becomes the
    /// heading when its words are exactly the chapter's title; otherwise an
    /// untimed heading line with the title is inserted there. One walk
    /// covers both ordered lists. An empty transcript stays empty, and a
    /// transcript without timestamps gets no headings, since they have no
    /// position to land on.
    private static func mergedLines(_ lines: [LyricLine], chapters: [Chapter]) -> (lines: [LyricLine], titles: [Int: Chapter]) {
        guard lines.contains(where: { $0.startSeconds != nil }) else { return (lines, [:]) }
        var merged: [LyricLine] = []
        var titles: [Int: Chapter] = [:]
        var lineIndex = 0
        for chapter in chapters {
            while lineIndex < lines.count, (lines[lineIndex].startSeconds ?? -1) < chapter.startSeconds - Chapter.startSlackSeconds {
                merged.append(lines[lineIndex])
                lineIndex += 1
            }
            titles[merged.count] = chapter
            if lineIndex < lines.count, matchesTitle(lines[lineIndex], of: chapter) {
                merged.append(lines[lineIndex])
                lineIndex += 1
            } else {
                merged.append(headingLine(for: chapter))
            }
        }
        merged.append(contentsOf: lines[lineIndex...])
        return (merged, titles)
    }

    /// True when the line's words are exactly the chapter's title, compared
    /// without case.
    private static func matchesTitle(_ line: LyricLine, of chapter: Chapter) -> Bool {
        let lineText = line.text.trimmingCharacters(in: .whitespaces)
        let title = chapter.title.trimmingCharacters(in: .whitespaces)
        return lineText.caseInsensitiveCompare(title) == .orderedSame
    }

    /// An untimed heading line holding the chapter's title, for chapters
    /// whose title is not read aloud. With no start time and no cues, the
    /// line never becomes the current line and never highlights. The
    /// negative index keeps it apart from the source lines.
    private static func headingLine(for chapter: Chapter) -> LyricLine {
        LyricLine(index: -1 - chapter.index, text: chapter.title, startSeconds: nil, cues: [])
    }

    // MARK: - Position lookups

    /// The array position of the line containing the playback position.
    func lineIndex(at seconds: Double) -> Int? {
        guard seconds > 0 else { return nil }
        let position = timedLines.partitioningIndex { $0.start > seconds }
        return position > 0 ? timedLines[position - 1].position : nil
    }

    /// The index of the line's last cue starting at or before the position.
    func spokenCueIndex(inLine line: Int, at seconds: Double) -> Int? {
        lines[line].cues.lastIndex(where: { $0.startSeconds <= seconds })
    }

    /// The next moment the current line or spoken cue changes: the first cue
    /// of the current line past the position, or the next timed line's start.
    func nextBoundarySeconds(after seconds: Double, currentLine: Int?) -> Double? {
        var next: Double?
        if let currentLine, lines.indices.contains(currentLine),
           let cue = lines[currentLine].cues.first(where: { $0.startSeconds > seconds }) {
            next = cue.startSeconds
        }
        if let lineStart = nextTimedLineStart(after: seconds), lineStart < next ?? .infinity {
            next = lineStart
        }
        return next
    }

    /// The start of the first timed line strictly past the position.
    private func nextTimedLineStart(after seconds: Double) -> Double? {
        let position = timedLines.partitioningIndex { $0.start > seconds }
        return position < timedLines.count ? timedLines[position].start : nil
    }

    // MARK: - Storage ranges

    /// The storage location where the line starts, or zero without a line.
    func lineStart(of line: Int?) -> Int {
        line.flatMap { lineRanges.indices.contains($0) ? lineRanges[$0].location : nil } ?? 0
    }

    /// The storage range spanning the given line positions, clamped to the
    /// known lines.
    func linesRange(from low: Int, to high: Int) -> NSRange {
        guard let first = lineRanges.indices.contains(low) ? lineRanges[low] : lineRanges.first,
              let last = lineRanges.indices.contains(high) ? lineRanges[high] : lineRanges.last
        else { return NSRange(location: 0, length: 0) }
        return NSRange(location: first.location, length: last.location + last.length - first.location)
    }

    /// The storage range of the given line's spoken cue.
    func spokenCueRange(line: Int?, cue: Int?) -> NSRange? {
        guard let line, let cue, lineRanges.indices.contains(line) else { return nil }
        let spoken = lines[line].cues[cue]
        let text = lines[line].text
        let readEnd = utf16Offset(ofCharacter: spoken.startPosition, in: text)
        let spokenEnd = utf16Offset(ofCharacter: spoken.endPosition, in: text)
        guard spokenEnd > readEnd else { return nil }
        return NSRange(location: lineRanges[line].location + readEnd, length: spokenEnd - readEnd)
    }

    /// The storage range centering targets: the spoken cue, or the current
    /// line's start before its first cue.
    func spokenTargetRange(line: Int?, cue: Int?) -> NSRange? {
        guard let line, lineRanges.indices.contains(line) else { return nil }
        let range = lineRanges[line]
        guard let cue else {
            return NSRange(location: range.location, length: 0)
        }
        let spoken = lines[line].cues[cue]
        let start = utf16Offset(ofCharacter: spoken.startPosition, in: lines[line].text)
        let end = utf16Offset(ofCharacter: spoken.endPosition, in: lines[line].text)
        return NSRange(location: range.location + start, length: max(0, end - start))
    }

    // MARK: - Color state

    /// The color inputs for the given position and matches, in storage
    /// offsets, for the color resolver.
    func colorState(currentLine: Int?, spokenCue cue: Int?, matches: [NSRange]) -> TranscriptColorState {
        var state = TranscriptColorState(readEnd: lineStart(of: currentLine), matches: matches)
        guard let currentLine, lineRanges.indices.contains(currentLine) else { return state }
        state.currentLineRange = lineRanges[currentLine]
        guard let cue, lines[currentLine].cues.indices.contains(cue) else { return state }
        let line = lines[currentLine]
        let start = utf16Offset(ofCharacter: line.cues[cue].startPosition, in: line.text)
        let end = utf16Offset(ofCharacter: line.cues[cue].endPosition, in: line.text)
        state.spokenCueStart = lineRanges[currentLine].location + start
        if end > start {
            state.spokenCueRange = NSRange(location: lineRanges[currentLine].location + start, length: end - start)
        }
        return state
    }

    // MARK: - Clicks

    /// Resolves a click: anywhere on a chapter heading hits the chapter,
    /// and a word elsewhere hits its cue. Clicks on whitespace or beside
    /// the words of a body line hit nothing.
    func tapTarget(atUTF16Index index: Int) -> TranscriptTapTarget? {
        let position = lineRanges.partitioningIndex { $0.location + $0.length >= index }
        guard position < lineRanges.count, index >= lineRanges[position].location else { return nil }
        if let chapter = titleChapters[position] {
            return .chapter(chapter)
        }
        let line = lines[position]
        let local = characterOffset(ofUTF16: index - lineRanges[position].location, in: line.text)
        guard let cue = cue(atCharacter: local, in: line) else { return nil }
        return .word(cue)
    }

    /// The cue of the word containing the character: the first cue that
    /// overlaps the whitespace-delimited word around it.
    private func cue(atCharacter position: Int, in line: LyricLine) -> LyricCue? {
        let characters = Array(line.text)
        guard position < characters.count, !characters[position].isWhitespace else { return nil }
        var start = position
        while start > 0, !characters[start - 1].isWhitespace { start -= 1 }
        var end = position
        while end < characters.count, !characters[end].isWhitespace { end += 1 }
        return line.cues.first(where: { $0.endPosition > start && $0.startPosition < end })
    }

    // MARK: - Character offsets

    /// Cue positions count characters; the storage counts UTF-16 units.
    private func utf16Offset(ofCharacter position: Int, in text: String) -> Int {
        let index = text.index(text.startIndex, offsetBy: min(position, text.count))
        return text.utf16.distance(from: text.utf16.startIndex, to: index)
    }

    private func characterOffset(ofUTF16 offset: Int, in text: String) -> Int {
        guard let utf16Index = text.utf16.index(text.utf16.startIndex, offsetBy: min(offset, text.utf16.count), limitedBy: text.utf16.endIndex),
              let index = utf16Index.samePosition(in: text)
        else { return 0 }
        return text.distance(from: text.startIndex, to: index)
    }
}

extension Array {
    /// The position of the first element in the suffix the predicate marks,
    /// or the count when the suffix is empty, by binary search. The array
    /// must order all non-matching elements before all matching ones.
    func partitioningIndex(where belongsToSuffix: (Element) -> Bool) -> Int {
        var low = 0
        var high = count
        while low < high {
            let mid = (low + high) / 2
            if belongsToSuffix(self[mid]) {
                high = mid
            } else {
                low = mid + 1
            }
        }
        return low
    }
}
