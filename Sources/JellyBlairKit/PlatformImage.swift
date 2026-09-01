import SwiftUI

#if canImport(AppKit)
import AppKit

/// The native image type of the current platform.
public typealias PlatformImage = NSImage
#else
import UIKit

/// The native image type of the current platform.
public typealias PlatformImage = UIImage
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
