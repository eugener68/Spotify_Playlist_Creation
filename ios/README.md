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
- Persist tokens with `SpotifyTokenStore` implementations (Keychain-backed or in-memory). Use `RefreshingAccessTokenProvider` to reuse/refresh tokens automatically; `AppDependencies.liveUsingKeychain` provisions a `KeychainTokenStore` for production builds while previews still rely on the in-memory store.
- SwiftUI hosts can now initialize `RootView(configuration:keychainService:keychainAccount:)` to automatically spin up PKCE + Keychain wiring without touching `AppDependencies` directly.
- Tests under `SpotifyAPIKitTests/PKCETests` + `RefreshingAccessTokenProviderTests` ensure challenge generation and refresh behavior stay deterministic. Extend them as additional grant types or storage strategies are added.
- When building on Apple platforms, `SpotifyAPIKitTests/KeychainTokenStoreTests` verifies the Keychain-backed token store can save, load, and clear credentials.

## Next Steps

1. Flesh out the PKCE implementation inside `SpotifyAPIKit` and connect it to `AuthenticationServices` from your iOS app target.
2. Port the playlist builder logic from `core/playlist_builder.py` into `DomainKit` using the fixtures defined in `Refactoring.md` Section 10.
3. Extend the `AutoPlaylistBuilderApp` Xcode project to add production UI polish (app icon, onboarding, etc.) as you iterate beyond the scaffold.
4. A GitHub Actions workflow (`.github/workflows/ios-swift-tests.yml`) now runs `swift test` from this directory on pushes and pull requests; it also builds the new iOS app target via `xcodebuild` on an iPhone simulator.

## AutoPlaylistBuilderApp (SwiftUI app)

The `App/AutoPlaylistBuilderApp` directory contains a ready-to-run SwiftUI app that embeds the `AppFeature` package:

- Open `App/AutoPlaylistBuilderApp/AutoPlaylistBuilderApp.xcodeproj` in Xcode 15+, select the **AutoPlaylistBuilderApp** scheme, and choose an iOS 17+ simulator.
- Copy `App/AutoPlaylistBuilderApp/AutoPlaylistBuilderApp/Resources/AppSecrets.example.plist` to `AppSecrets.plist`, then fill in your Spotify Client ID, redirect URI, and scopes. The example file stays in the bundle for previews; the real secrets file is ignored via `.gitignore`.
- Update `Info.plist` (URL types) so the redirect scheme matches the one registered on the Spotify dashboard.
- The `RootView(configuration:keychainService:keychainAccount:)` convenience initializer is used inside `AutoPlaylistBuilderApp.swift`, so tokens persist automatically via the Keychain-backed dependency wiring.

## DJ AI Subscription + Lifetime (StoreKit 2)

The DJ AI feature (artist ideas generation) is gated behind StoreKit 2 purchases:

- **Auto-renewable subscription** (weekly / monthly / yearly) in a single subscription group.
- **Lifetime** as a **non-consumable** IAP that unlocks DJ AI permanently.

The app expects product identifiers with this default pattern (based on your bundle identifier):

- `$(BUNDLE_ID).dj.ai.weekly`
- `$(BUNDLE_ID).dj.ai.monthly`
- `$(BUNDLE_ID).dj.ai.yearly`
- `$(BUNDLE_ID).dj.ai.lifetime`

Optionally, you can also configure a limited-time founders SKU:

- `$(BUNDLE_ID).dj.ai.founders.lifetime`

The app will **stop showing** the founders SKU after **12/31/2026**, or after the user has **started a trial** or **purchased any DJ AI subscription**.

The **7-day free trial** is configured as an **Introductory Offer** on the subscription products in App Store Connect (not hard-coded in the app).
