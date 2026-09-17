import SwiftUI

/// A symbol icon, defined once and rendered through these accessors
/// wherever it appears. The plain form is the template symbol, in the
/// context's own color. The accented forms show the accent color: a plain
/// glyph colors whole, and a symbol with a glyph layer over a fill colors
/// the fill and draws the glyph in white.
public struct Icon {
    let name: String
    /// True when the symbol draws a glyph layer over a filled shape.
    let hasGlyphLayer: Bool

    public init(_ name: String, hasGlyphLayer: Bool = false) {
        self.name = name
        self.hasGlyphLayer = hasGlyphLayer
    }

    /// The icon in the context's own color.
    public var plain: Image {
        Image(systemName: name)
    }

    /// The icon in the accent color, as a styled view. The palette style
    /// survives the toolbar, which repaints plain template icons in its
    /// own color but keeps palette styles.
    @ViewBuilder
    public var accented: some View {
        if hasGlyphLayer {
            plain
                .symbolRenderingMode(.palette)
                .foregroundStyle(Color.white, Color.accentColor)
        } else {
            plain
                .symbolRenderingMode(.palette)
                .foregroundStyle(Color.accentColor)
        }
    }

    /// The icon in the accent color, as a ready-made image for the native
    /// menus, which drop styles and paint template icons in their own
    /// color. The environment resolves the accent into a concrete color.
    public func accentedImage(in environment: EnvironmentValues) -> Image {
        guard let image = paletteSymbol(name, colors: accentPalette(in: environment)) else { return plain }
        return Image(platformImage: image)
    }

    /// The icon in red, as a ready-made image for the native menus'
    /// destructive items. The Mac's menus draw the destructive role in
    /// the plain menu color, so the red is baked into the image.
    public var destructiveImage: Image {
        guard let image = paletteSymbol(name, colors: [.systemRed]) else { return plain }
        return Image(platformImage: image)
    }

    /// The accent palette: white over the accent for a layered symbol,
    /// and the accent alone for a plain glyph.
    private func accentPalette(in environment: EnvironmentValues) -> [PlatformColor] {
        let accent = resolvedAccent(in: environment)
        return hasGlyphLayer ? [.white, accent] : [accent]
    }
}

/// The accent color as a concrete native color. The Mac's accent is
/// concrete already; the iOS placeholder resolves through the view
/// environment.
private func resolvedAccent(in environment: EnvironmentValues) -> PlatformColor {
    #if canImport(AppKit)
    return .accent
    #else
    return UIColor(cgColor: Color.accentColor.resolve(in: environment).cgColor)
    #endif
}
