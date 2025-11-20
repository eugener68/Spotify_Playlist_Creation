# Native iOS Rewrite Plan (SwiftUI – Option B)

## 1. Context & Goals

- Existing app: Python + Kivy desktop experience packaged with PyInstaller; handles Spotify OAuth (PKCE) and playlist assembly with in-process HTTP servers and threading.
- Objective: Build a first-class SwiftUI iPhone app that follows Apple Human Interface Guidelines, leverages modern APIs (Swift Concurrency, Combine, SafariServices/AuthenticationServices), and re-implements all user-facing behavior natively.
- Approach: Keep the product functionality (playlist builder inputs, Spotify automation) while re-creating both UI and domain logic in Swift. Python code remains a reference during the rewrite but will not ship on iOS.

## 2. Current Desktop Architecture (Reference)

| Layer | Notes |
| --- | --- |
| Entry (`main.py`) | Configures logging/env discovery and launches the Kivy app. |
| UI (`app/app.py`, `app/ui/main.kv`) | Desktop-oriented layout, Tkinter file dialogs, keyboard-first workflow. |
| Controllers | `AuthController` manages PKCE via local HTTP server; `PlaylistController` runs builder threads and updates shared state. |
| Domain logic (`core/`) | `playlist_builder.py`, `playlist_options.py` encode playlist assembly algorithms. |
| Services (`services/`) | HTTPX clients for Spotify OAuth + Web API. |
| Packaging | PyInstaller/Buildozer output for desktop/Android; no iOS artifacts. |

This snapshot is the functional spec we will port to Swift.

## 3. Target Native iOS Architecture

| Layer | Swift Component |
| --- | --- |
| UI | SwiftUI views organized with MVVM, adaptive layouts, and accessibility semantics. |
| Navigation & State | ObservableObject view models + Redux-style store for playlist options, auth status, and build progress. |
| Domain Layer | Swift modules mirroring `PlaylistOptions`, `PlaylistBuilder`, and stats computation, using Swift structs and Combine publishers. |
| Networking | `URLSession` + async/await for Spotify Web API, strongly typed DTOs, retry/error policies. |
| Authentication | `AuthenticationServices.ASWebAuthenticationSession` for PKCE, SafariServices fallback, custom URL scheme callback handling. |
| Secrets & Storage | Keychain for tokens, `AppStorage`/`FileManager` for playlist preferences, Secure Enclave flags when possible. |
| Background Work | `Task` + `TaskGroup` for concurrent fetches; `BGProcessingTaskRequest` (future) for long builds; gracefully handles foreground/background transitions. |
| Packaging | Xcode workspace, Swift Package Manager modules, automated tests + TestFlight distribution. |

## 4. Core Workstreams

1. **Domain logic port** – translate playlist builder algorithms and data models into Swift structs/classes with unit tests mirroring Python behavior.
2. **Spotify OAuth** – implement PKCE generation, ASWebAuthenticationSession flow, custom URL scheme registration, and token refresh scheduling.
3. **SwiftUI experience** – design native screens (auth, playlist configuration, results) with focus on accessibility, dynamic type, safe areas, drag-and-drop, and Files integration.
4. **Persistence & secrets** – design secure storage (Keychain) plus on-device caching of playlist preferences using `Codable` + `FileManager`/`UserDefaults`.
5. **Networking & concurrency** – build reusable Spotify client leveraging async/await, URLSession metrics, and error surfaces consistent with iOS networking best practices.
6. **Compliance & permissions** – manage Info.plist entries, privacy strings, background execution policies, and App Store review assets.
7. **Build, QA, release** – create Xcode project/targets, CI (Xcode Cloud or GitHub Actions w/ xcodebuild), TestFlight rollout, telemetry/logging strategy.

## 5. Detailed Plan

### 5.1 Domain Logic Migration

- Model `PlaylistOptions` as a `Codable` struct; ensure parity with existing defaults (limits, shuffle, dedupe, reuse, etc.).
- Recreate `PlaylistBuilder` in Swift using dependency injection for the Spotify client so it can be unit-tested without network calls.
- Define a `PlaylistStats` value type that reproduces the desktop stats output (prepared count, added count, reuse info) for use in UI popovers.
- Port helper behaviors (artist parsing, dedupe logic, truncation rules) and cover them with XCTest cases referencing fixture data exported from the Python version.

### 5.2 OAuth & Account Flow

- Register a new Spotify app for iOS with redirect URI `autoplaylistbuilder://callback` (or equivalent) and enable PKCE.
- Implement PKCE primitives (code verifier/challenge, state nonce) natively in Swift.
- Use `ASWebAuthenticationSession` to launch the Spotify authorize URL; handle completion via custom scheme handler implemented in the app delegate / SwiftUI lifecycle.
- Persist tokens (access + refresh) and expiry timestamps inside the Keychain; schedule silent refresh using background `Task` when expiry nears.
- Provide a fallback SafariServices sheet for older iOS versions if ASWebAuthenticationSession is unavailable.

### 5.3 SwiftUI Experience

- Create dedicated flows:
  - **Onboarding/Auth**: explain scopes, show sign-in state, handle failures with actionable copy.
  - **Playlist Options**: SwiftUI forms with pickers, toggles, text fields, inline validation, and attachments to Files app for artist lists.
  - **Build Progress**: progress view with cancellable tasks, stats summary sheets, Share button for playlist links.
- Support Dynamic Type, VoiceOver labels, and haptics for critical actions.
- Add `UIDocumentPickerViewController` via `UIViewControllerRepresentable` for importing artist files and store them in app sandbox.

### 5.4 Persistence, Secrets, and Filesystem

- Keychain wrapper built with `Security` framework for tokens and refresh data; include unit tests using `SecItemCopyMatching` stubs.
- Store playlist preference drafts in `FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)` as JSON; mirror to `AppStorage` for lightweight defaults.
- Provide import/export of `.env`-style templates via Files app while keeping secrets out of source control.

### 5.5 Networking, Permissions, Backgrounding

- Build a `SpotifyAPIClient` with typed requests/responses using async `URLSession.data(for:)`, automatic rate-limit handling, and instrumentation for `MetricsKit`.
- Centralize error mapping (e.g., auth expired, network unreachable, DNS failure) into user-friendly messages.
- Declare `NSAppTransportSecurity` exceptions only if absolutely necessary; prefer HTTPS for all endpoints.
- Plan for background-safe playlist construction by chunking API calls and respecting watchdog limits; consider `BGProcessingTaskRequest` for long operations in future releases.

### 5.6 Build, QA, Release

- Initialize a Swift Package Manager workspace: `spotify-playlist-builder-ios` with modules for Domain, Networking, UI, and App.
- Configure GitHub Actions (macOS runners) to run `xcodebuild -scheme SpotifyPlaylistBuilder -destination 'platform=iOS Simulator,name=iPhone 15' test` on every PR.
- Instrument analytics/logging via OSLog categories stored locally (forward to export via Files when debugging).
- Prepare App Store Connect metadata, privacy policy (document Spotify data usage), and beta test instructions.

### 5.7 Delivery Milestones (suggested)

| Milestone | Scope |
| --- | --- |
| M1 – Foundation | Swift package skeleton, PlaylistOptions model, PKCE utilities, unit tests. |
| M2 – OAuth & Basic UI | ASWebAuthenticationSession flow, sign-in/out views, Keychain storage. |
| M3 – Playlist Builder | Networking client, domain logic port, build workflow UI + dry-run support. |
| M4 – Polish & Compliance | Files integration, accessibility pass, App Store artifacts, TestFlight beta. |

## 6. Dependencies & Risks

- **Algorithm parity** – ensure Swift port matches Python behavior; rely on golden files/tests to avoid regressions.
- **Spotify policy changes** – verify mobile redirect URI approval and quota limits early.
- **App Store review** – include disclosures for Spotify data, network usage, and any background tasks.
- **Security** – Keychain misuse or insecure storage will block review; prioritize from day one.
- **Timeline** – Native rewrite is larger than adapting Kivy; allocate time for design, Swift development, and QA.

## 7. Pre-Mac Action Items (Can Start Now)

1. **Specification pack** – document every screen, setting, and playlist rule in a product spec (derive from Python UI + README) to guide SwiftUI design.
2. **Algorithm translation notes** – annotate `core/playlist_builder.py` with comments describing each step; extract sample inputs/outputs to use as unit-test fixtures in Swift later.
3. **Spotify app prep** – draft required scopes, redirect URIs, and client naming so the iOS app registration is ready when Xcode work begins.
4. **Data contract diagrams** – define JSON schemas for Spotify responses currently used; will convert to Swift Codable structs.
5. **Design wireframes** – sketch SwiftUI layouts (Figma or PencilKit) referencing Apple HIG, including dark mode and accessibility considerations.
6. **CI planning** – outline the macOS CI environment (mac minis, GitHub-hosted runners) and caching strategy for future Xcode builds.

Completing these tasks now shortens the actual Swift build once the macOS/Xcode environment is available.

## 8. Existing Spotify Developer Configuration

| Field | Current Value |
| --- | --- |
| App name | AutoPlaylistBuilder |
| Description | Creates a playlist for the user from the provided artist list or from favorite artists, containing the top tracks per artist. |
| Website | (configured in dashboard) |
| Redirect URIs | `myapp-ios://callback`, `http://127.0.0.1:8765/callback`, `myapp-android://callback`, `http://[::1]:8765/callback` |
| Bundle IDs | `eugener68.autoplaylistbuilder` |
| Android packages | (configured in dashboard) |
| APIs enabled | Android, Web API, iOS |

These identifiers can be referenced directly when setting up the SwiftUI app target (Bundle ID + iOS redirect URI) and future Android work. Keep the dashboard entries in sync with any new schemes or package identifiers introduced during development.

## 9. Product Specification (Desktop Parity Checklist)

| Flow | Requirements to Mirror in SwiftUI |
| --- | --- |
| Onboarding & Auth | Explain requested scopes, show current auth state (“Not signed in”, “Signed in as …”), surface errors, and provide single CTA to start/stop OAuth. Display granted scopes and user display name once authenticated. |
| Playlist Configuration | Inputs for playlist name, per-artist limit, max artists/tracks, shuffle seed, boolean toggles (date stamp, dedupe, print tracks, shuffle, reuse existing, truncate, verbose, include library/followed artists). Manual artists text area plus optional artist file picker; immediate validation and persistence. |
| File Import | Allow users to select a text file listing artists (one per line) from Files/iCloud/On-device storage; show selected path and allow clearing. |
| Build Controls | Buttons for Dry Run and Build Playlist, disabled when not authenticated or when build is in progress. Provide open-latest-playlist button when a URL exists. |
| Status & Feedback | Real-time labels for auth status, build status, build details (playlist name, prepared count, uploaded count, reused flag), stats text block, and pop-up sheet summarizing build metrics. |
| Logging & Troubleshooting | Present toast/banner when errors occur (auth failure, build exception, network lookup issues). Offer link or share sheet to copy logs later. |
| Settings | Surface client ID (if user-editable), redirect URI info, theme options, and ability to sign out/clear cached data. |

Additional UX notes:

- **Responsive layout:** Primary workflow is portrait with scrollable sections; keep CTAs anchored near bottom for thumb reach.
- **Accessibility:** Support Dynamic Type, VoiceOver labels for toggles/inputs, and focus order matching the logical playlist-building steps.
- **State restoration:** Persist unfinished playlist options locally so reopening the app resumes where the user left off.
- **Error copy:** Reuse the descriptive strings from `AppState.mark_auth_failure` and `mark_build_failure`, adapting tone for iOS alerts.

## 10. Playlist Builder Reference Fixtures

These scenarios capture deterministic inputs/outputs that we can convert into Swift unit tests by stubbing the Spotify client responses.

### Fixture A – Manual Artists, Dedupe On, Dry Run

- **Options**
  - Playlist name: "Road Trip Mix"
  - Date stamp: true (expect `Road Trip Mix 2025-11-20` when generated on that date)
  - Manual artists: `["Metallica", "A-ha"]`
  - Limit per artist: 3, max artists: 10, max tracks: 20
  - Shuffle: false, Dedupe variants: true, Reuse existing: false, Dry run: true
- **Stubbed API**
  - `search_artists("Metallica") → Artist(id="metallica", name="Metallica")`
  - `top_tracks_for_artist("metallica", limit=3)` returns tracks `m1`, `m2`, `m3`
  - Similar pattern for `A-ha` with track IDs `aha1`, `aha2`, `aha3`
- **Expected Result**
  - `prepared_track_uris = ["spotify:track:m1", "spotify:track:m2", ... "spotify:track:aha3"]`
  - `stats = (artists_retrieved=2, top_tracks_retrieved=6, variants_deduped=0, total_prepared=6, total_uploaded=0)`
  - `display_tracks` shows "Metallica – Track Name" entries matching `_format_track` logic.

### Fixture B – Reuse Existing Playlist with Shuffle

- **Options**
  - Playlist name: "Morning Mix", date stamp off, reuse existing on, shuffle on with seed `1234`
  - Limit per artist: 2, max tracks: 5, truncate: false
- **Stubbed API**
  - Existing playlist summary with ID `old123`, existing tracks `[t1, t2, t3]`
  - New prepared tracks `[n1, n2, n3, n4, n5]` (already deduped)
- **Expected Result**
  - Builder compares prepared URIs against existing; `added_track_uris` is subset not already on playlist.
  - Since shuffle + reuse is enabled, combined URIs (prepared + remaining existing) are shuffled with deterministic order from seed `1234` and `replace_playlist_tracks` is invoked once.
  - `stats.total_uploaded` equals count of newly added URIs.

### Fixture C – Truncate Existing Playlist

- **Options**
  - Reuse existing playlist enabled, truncate true, shuffle false.
  - Prepared tracks exceed max (e.g., 50), `max_tracks=25`.
- **Expected Result**
  - `trim_tracks` ensures only first 25 URIs upload; `replace_playlist_tracks` is called even if existing playlist had more tracks.
  - `stats.total_uploaded = 25`, `prepared_track_uris` size matches `max_tracks`.

For each fixture we can serialize the option payloads (as JSON) and the mocked Spotify responses to drive Swift unit tests without live network traffic.

## 11. Spotify Web API Schemas (for Swift Codable Models)

| Endpoint | Method/Path | Key Fields Consumed |
| --- | --- | --- |
| Current user profile | `GET /me` | `id` (string), `display_name` (string?), `email` (string?), `product`, `country`. Required: `id`, fallback to `email` for display. |
| Followed artists | `GET /me/following?type=artist&limit=50` | Response root `{ "artists": { "items": [ {"id","name"} ], "cursors": {"after"}, "next" } }`. Only `id`, `name`, `next`, `cursors.after` are used. |
| User top artists | `GET /me/top/artists` | Items array containing `id`, `name`. Pagination via `next`, `offset`, `limit`. |
| Artist lookup | `GET /artists/{id}` | Fields `id`, `name`. |
| Artist search | `GET /search?type=artist&q={query}` | Result shape `{ "artists": { "items": [ {"id","name"} ] } }`. Also used for fuzzy match logic. |
| Top tracks for artist | `GET /artists/{id}/top-tracks?market=from_token` | Each track includes `id`, `name`, `artists` (array of `{name}`). Only these fields are required for builder output. |
| Create playlist | `POST /users/{user_id}/playlists` with body `{"name","description","public"}` | We consume `id` from response. |
| Replace playlist tracks | `PUT /playlists/{playlist_id}/tracks` body `{ "uris": ["spotify:track:..."] }` | No JSON body expected on success (204). |
| Add tracks to playlist | `POST /playlists/{playlist_id}/tracks` body `{ "uris": [...] }` | Response not inspected. |
| Get playlist tracks | `GET /playlists/{playlist_id}/tracks?limit=100&offset=n` | Items array where `item.track.uri` yields Spotify URI, `next` indicates additional pages. |
| List user playlists | `GET /me/playlists` | Items include `id`, `name`, `owner.id`, `tracks.total`. Used by `find_playlist_by_name`. |

Sample Swift Codable skeletons can therefore stay lean, e.g.:

```swift
struct SpotifyArtist: Codable { let id: String; let name: String }
struct SpotifyTrack: Codable { let id: String; let name: String; let artists: [SpotifyArtist] }
struct CurrentUserResponse: Codable { let id: String; let displayName: String?; let email: String? }
```

Keep these contracts versioned so the native client can detect API changes without inspecting Spotify docs during build time.

## 12. CI / Testing Strategy (Pre-Mac Preparation)

1. **Repo layout**

   - Keep Swift sources under `ios/` with Swift Package Manager support so unit tests can run via `swift test` before the Xcode UI exists.
   - Maintain Python folder for reference but mark it as legacy.

2. **GitHub Actions pipeline design**

   - Workflow `ci-ios.yml` triggered on PRs and pushes to `ios-refactoring`/`main`.
   - Jobs:
     - `lint-docs`: Run markdown lint (e.g., `markdownlint-cli2`) to keep planning docs consistent.
     - `swift-format` (later) to enforce style once Swift sources exist.
     - `unit-tests`: macOS 14 runner executing `xcodebuild test -scheme SpotifyPlaylistBuilder -destination 'platform=iOS Simulator,name=iPhone 15'`.
   - Cache derived data (`~/Library/Developer/Xcode/DerivedData`) and SwiftPM artifacts to reduce build time.

3. **Secrets handling**

   - No Spotify Client Secret stored in CI; only Client ID if absolutely required for integration tests (prefer mocking).
   - Use GitHub Encrypted Secrets for ephemeral tokens when needed.

4. **Test pyramid**

   - **Unit tests**: Port fixtures from Section 10 into XCTest; mock Spotify client using protocols.
   - **Integration tests**: Run a limited set against Spotify Sandbox (if available) using CI-only credentials; guard with manual approval.
   - **UI tests**: Xcode UI tests covering auth happy path, playlist build, and error surfaces (once UI stabilizes).

5. **Static analysis & security**

   - Enable Xcode build settings for warnings-as-errors, SwiftLint (optional) for code hygiene, and `codesign --verify` steps before distributing artifacts.

6. **Artifacts**

   - Upload `.xcresult` bundles and, for release branches, the signed `.ipa` for TestFlight submission.

7. **Local parity**

   - Provide `make test-ios` script mirroring CI commands so developers without CI can validate changes locally before pushing.

These steps can be documented now so once a macOS runner is available the workflow file can be added with minimal iteration.
