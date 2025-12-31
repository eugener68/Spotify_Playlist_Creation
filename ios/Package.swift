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
            name: "AppleMusicAPIKit",
            targets: ["AppleMusicAPIKit"]
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
            name: "AppleMusicAPIKit",
            dependencies: ["DomainKit"]
        ),
        .target(
            name: "AppFeature",
            dependencies: ["DomainKit", "SpotifyAPIKit", "AppleMusicAPIKit"],
            resources: [
                .process("Resources")
            ]
        ),
        .testTarget(
            name: "DomainKitTests",
            dependencies: ["DomainKit"],
            resources: [
                .process("Fixtures")
            ]
        ),
        .testTarget(
            name: "SpotifyAPIKitTests",
            dependencies: ["SpotifyAPIKit"]
        ),
        .testTarget(
            name: "AppleMusicAPIKitTests",
            dependencies: ["AppleMusicAPIKit"]
        )
    ]
)
