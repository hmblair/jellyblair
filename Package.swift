// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "JellyBlair",
    platforms: [.macOS(.v15), .iOS(.v18)],
    products: [
        .library(name: "JellyBlairKit", targets: ["JellyBlairKit"]),
    ],
    targets: [
        .target(
            name: "JellyBlairKit",
            path: "Sources/JellyBlairKit",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
