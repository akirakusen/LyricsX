// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "LyricsXPlayerSupport",
    platforms: [.macOS(.v12)],
    products: [
        .library(name: "LyricsXPlayerSupport", targets: ["LyricsXPlayerSupport"]),
    ],
    targets: [
        .target(name: "LyricsXPlayerSupport", path: "Shared"),
        .testTarget(
            name: "LyricsXPlayerSupportTests",
            dependencies: ["LyricsXPlayerSupport"],
            path: "Tests/LyricsXPlayerSupportTests"
        ),
    ]
)
