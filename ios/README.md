# AutoPlaylistBuilder iOS Scaffold

This directory hosts the Swift Package that will evolve into the full native SwiftUI application. The package is intentionally lightweight so it can be cloned and iterated on from macOS without requiring the rest of the Python/Kivy tooling.

## Targets

| Target | Type | Purpose |
| --- | --- | --- |
| `DomainKit` | Library | Playlist options, stats, and builder abstractions recreated in Swift. |
| `SpotifyAPIKit` | Library | URLSession-based Spotify Web API client with PKCE plumbing. |
| `AppFeature` | Library | SwiftUI entry points, view models, and dependency composition. |
| `DomainKitTests` | Test | XCTest suite that will replay the fixtures described in `Refactoring.md`. |

## Getting Started (on macOS)

```bash
cd ios
swift package resolve
swift test
```

The current sources only provide scaffolding, so tests simply verify model defaults. As features land, add new test targets or an Xcode project referencing this package.

## Next Steps

1. Flesh out the PKCE implementation inside `SpotifyAPIKit` and connect it to `AuthenticationServices` from your iOS app target.
2. Port the playlist builder logic from `core/playlist_builder.py` into `DomainKit` using the fixtures defined in `Refactoring.md` Section 10.
3. Create an Xcode app project that consumes `AppFeature` and hosts the SwiftUI views described in the product spec.
4. Wire the GitHub Actions workflow (Section 12 of `Refactoring.md`) to run `swift test` from this directory.
