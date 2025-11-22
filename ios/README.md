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

## DomainKit Scaffolding

- `PlaylistBuilder` now resolves manual artist queries, fetches top tracks, dedupes results, and formats stats for dry-run executions.
- `PlaylistBuilderTests.testFixtureAManualArtistsDryRun` mirrors Fixture A in `Refactoring.md` to keep the Swift implementation aligned with the Python reference logic.
- Extend the same pattern for Fixtures B and C by dropping additional mocks into `DomainKitTests` and asserting playlist reuse, shuffle ordering, and truncation.

Run the focused test from this directory with:

```bash
swift test --filter PlaylistBuilderTests/testFixtureAManualArtistsDryRun
```

## SpotifyAPIKit Plumbing

- `SpotifyAPIClient` now conforms to `SpotifyProfileProviding`, `SpotifyArtistProviding`, `SpotifyTrackProviding`, and `SpotifyPlaylistEditing`, so `PlaylistBuilder` can execute real Spotify searches/top-track pulls once an access token is available.
- Tokens flow through the new `SpotifyAccessTokenProviding` protocol. Use the provided `InMemoryAccessTokenProvider` to stash short-lived tokens or implement your own provider that refreshes PKCE credentials.
- `AppDependencies.live(configuration:tokenProvider:)` wires a concrete client into `PlaylistBuilder` so SwiftUI views only need to supply a token provider after OAuth completes.
- `SpotifyAPIKitTests/SpotifyAPIClientTests` cover JSON decoding and error propagation using a custom `URLProtocol` stub. Add more tests as new endpoints land.
- PKCE support lives in `SpotifyPKCEAuthenticator`. Call `makeAuthorizationSession()` to build the authorise URL for `ASWebAuthenticationSession`, then pass the returned `codeVerifier` into `exchangeCode(_:codeVerifier:)` once you receive the redirect callback.
- Persist tokens with `SpotifyTokenStore` implementations (Keychain-backed or in-memory). Use `RefreshingAccessTokenProvider` to reuse/refresh tokens automatically; this is what `AppDependencies.liveWithPKCE` wires up for you.
- Tests under `SpotifyAPIKitTests/PKCETests` + `RefreshingAccessTokenProviderTests` ensure challenge generation and refresh behavior stay deterministic. Extend them as additional grant types or storage strategies are added.

## Next Steps

1. Flesh out the PKCE implementation inside `SpotifyAPIKit` and connect it to `AuthenticationServices` from your iOS app target.
2. Port the playlist builder logic from `core/playlist_builder.py` into `DomainKit` using the fixtures defined in `Refactoring.md` Section 10.
3. Create an Xcode app project that consumes `AppFeature` and hosts the SwiftUI views described in the product spec.
4. Wire the GitHub Actions workflow (Section 12 of `Refactoring.md`) to run `swift test` from this directory.
