import SwiftUI

#if canImport(AppKit)
import AppKit

/// The native image type of the current platform.
public typealias PlatformImage = NSImage
/// The native view type of the current platform.
typealias PlatformNativeView = NSView
/// The native font type of the current platform.
typealias PlatformFont = NSFont
/// The native color type of the current platform.
typealias PlatformColor = NSColor
/// The native scroll view type of the current platform.
typealias PlatformScrollView = NSScrollView

/// UIKit's semantic color names on NSColor, so shared code reads the same
/// on both platforms.
extension NSColor {
    static var secondaryLabel: NSColor { .secondaryLabelColor }
    static var label: NSColor { .labelColor }
    static var accent: NSColor { .controlAccentColor }
    /// The color of search matches, everywhere search highlights text.
    static var matchHighlight: NSColor { .systemGreen }
}
#else
import UIKit

/// The native image type of the current platform.
public typealias PlatformImage = UIImage
/// The native view type of the current platform.
typealias PlatformNativeView = UIView
/// The native font type of the current platform.
typealias PlatformFont = UIFont
/// The native color type of the current platform.
typealias PlatformColor = UIColor
/// The native scroll view type of the current platform.
typealias PlatformScrollView = UIScrollView

/// The accent color under the same name as its NSColor counterpart.
extension UIColor {
    static var accent: UIColor { .tintColor }
    /// The color of search matches, everywhere search highlights text.
    static var matchHighlight: UIColor { .systemGreen }
}
#endif

#if canImport(AppKit)
/// A symbol tinted in one color as a non-template image, so even the Mac's
/// toolbar, which paints template icons in its own color, renders the tint.
/// The tint fills the symbol's monochrome shape, so its cutouts stay. The
/// size configuration matches the symbols the toolbar draws itself.
func tintedSymbol(_ name: String, color: NSColor) -> NSImage? {
    let configuration = NSImage.SymbolConfiguration(textStyle: .body, scale: .large)
    guard let symbol = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
        .withSymbolConfiguration(configuration) else { return nil }
    return NSImage(size: symbol.size, flipped: false) { rect in
        symbol.draw(in: rect)
        color.set()
        rect.fill(using: .sourceAtop)
        return true
    }
}
#endif

extension Image {
    /// Creates an Image from the platform's native image type.
    init(platformImage: PlatformImage) {
        #if canImport(AppKit)
        self.init(nsImage: platformImage)
        #else
        self.init(uiImage: platformImage)
        #endif
    }
}
