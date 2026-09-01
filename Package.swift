// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "JellyBlair",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        .library(name: "JellyBlairKit", targets: ["JellyBlairKit"]),
        .executable(name: "JellyBlair", targets: ["JellyBlair"]),
    ],
    targets: [
        .target(
            name: "JellyBlairKit",
            path: "Sources/JellyBlairKit",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "JellyBlair",
            dependencies: ["JellyBlairKit"],
            path: "Sources/JellyBlair",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
