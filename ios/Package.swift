// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "AutoPlaylistBuilder",
    defaultLocalization: "en",
    platforms: [
        .iOS(.v16),
        .macOS(.v13)
    ],
    products: [
        .library(
            name: "DomainKit",
            targets: ["DomainKit"]
        ),
        .library(
            name: "SpotifyAPIKit",
            targets: ["SpotifyAPIKit"]
        ),
        .library(
            name: "AppFeature",
            targets: ["AppFeature"]
        )
    ],
    dependencies: [],
    targets: [
        .target(
            name: "DomainKit",
            resources: [
                .process("Resources")
            ]
        ),
        .target(
            name: "SpotifyAPIKit",
            dependencies: ["DomainKit"]
        ),
        .target(
            name: "AppFeature",
            dependencies: ["DomainKit", "SpotifyAPIKit"]
        ),
        .testTarget(
            name: "DomainKitTests",
            dependencies: ["DomainKit"],
            resources: [
                .process("Fixtures")
            ]
        )
    ]
)
