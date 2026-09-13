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

/// A symbol as a palette-colored symbol image. The palette makes the
/// image non-template, so the native menus, which paint template icons in
/// their own color, render the palette's colors. The image stays a symbol
/// image, so the menus keep sizing it themselves.
func paletteSymbol(_ name: String, colors: [PlatformColor]) -> PlatformImage? {
    #if canImport(AppKit)
    return NSImage(systemSymbolName: name, accessibilityDescription: nil)?
        .withSymbolConfiguration(NSImage.SymbolConfiguration(paletteColors: colors))
    #else
    return UIImage(systemName: name, withConfiguration: UIImage.SymbolConfiguration(paletteColors: colors))
    #endif
}

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
