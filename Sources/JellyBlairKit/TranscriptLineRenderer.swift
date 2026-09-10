import Foundation
#if canImport(AppKit)
import AppKit
#else
import UIKit
#endif

/// The transcript's one text engine: a private TextKit stack that measures,
/// draws, and hit-tests a single line at a time. Every consumer shares this
/// engine and its configuration, so a line wraps identically wherever it is
/// asked about, and a measured height is exactly the drawn height.
@MainActor
final class TranscriptLineRenderer {
    private let storage = NSTextStorage()
    private let layoutManager = NSLayoutManager()
    private let container: NSTextContainer

    /// The line and width the stack holds, so consecutive questions about
    /// one line lay it out once.
    private var installed: (line: NSAttributedString, width: CGFloat)?

    init() {
        container = NSTextContainer(size: CGSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        layoutManager.addTextContainer(container)
        storage.addLayoutManager(layoutManager)
    }

    /// Installs the line at the width, unless the stack already holds it.
    private func install(_ line: NSAttributedString, width: CGFloat) {
        if let installed, installed.line === line, installed.width == width { return }
        container.size = CGSize(width: width, height: CGFloat.greatestFiniteMagnitude)
        storage.setAttributedString(line)
        installed = (line, width)
    }

    /// The height of the line's text wrapped at the width.
    func textHeight(of line: NSAttributedString, width: CGFloat) -> CGFloat {
        install(line, width: width)
        _ = layoutManager.glyphRange(for: container)
        return ceil(layoutManager.usedRect(for: container).height)
    }

    /// Draws the line into the current graphics context at the origin.
    func draw(_ line: NSAttributedString, width: CGFloat, at origin: CGPoint) {
        install(line, width: width)
        let glyphs = layoutManager.glyphRange(for: container)
        layoutManager.drawBackground(forGlyphRange: glyphs, at: origin)
        layoutManager.drawGlyphs(forGlyphRange: glyphs, at: origin)
    }

    /// The frame of the character range within the line, in line
    /// coordinates. A zero-length range yields its insertion point's line
    /// fragment, so an empty target still names a visual line.
    func rect(forCharacterRange range: NSRange, in line: NSAttributedString, width: CGFloat) -> CGRect? {
        guard line.length > 0 else { return nil }
        install(line, width: width)
        _ = layoutManager.glyphRange(for: container)
        guard range.length > 0 else {
            let character = min(max(range.location, 0), line.length - 1)
            let glyph = layoutManager.glyphIndexForCharacter(at: character)
            return layoutManager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
        }
        let glyphs = layoutManager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
        guard glyphs.length > 0 else { return nil }
        return layoutManager.boundingRect(forGlyphRange: glyphs, in: container)
    }

    /// The UTF-16 index of the character at the point in line coordinates,
    /// or nil when the point misses the line's text.
    func characterIndex(at point: CGPoint, in line: NSAttributedString, width: CGFloat) -> Int? {
        guard line.length > 0 else { return nil }
        install(line, width: width)
        _ = layoutManager.glyphRange(for: container)
        guard layoutManager.usedRect(for: container).contains(point) else { return nil }
        var fraction: CGFloat = 0
        let glyph = layoutManager.glyphIndex(for: point, in: container, fractionOfDistanceThroughGlyph: &fraction)
        return layoutManager.characterIndexForGlyph(at: glyph)
    }
}
