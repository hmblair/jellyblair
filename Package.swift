// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "JellyBlair",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "JellyBlair",
            path: "Sources/JellyBlair",
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
