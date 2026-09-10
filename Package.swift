// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "JellyBlair",
    platforms: [.macOS(.v26), .iOS(.v26)],
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
