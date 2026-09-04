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

/// UIKit's semantic color names on NSColor, so shared code reads the same
/// on both platforms.
extension NSColor {
    static var secondaryLabel: NSColor { .secondaryLabelColor }
    static var label: NSColor { .labelColor }
    static var accent: NSColor { .controlAccentColor }
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

/// The accent color under the same name as its NSColor counterpart.
extension UIColor {
    static var accent: UIColor { .tintColor }
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
