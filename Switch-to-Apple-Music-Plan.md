# Switch to Apple Music (Primary Track Source) — Plan

## Goal
Make Apple Music the **primary source of tracks** (catalog search + metadata + playlist creation), and remove dependency on Spotify Web API for track sourcing. Spotify may remain as an optional export/secondary provider later.

This plan is written for the iOS app in this repo (Swift + MusicKit), and assumes public App Store distribution.

## Constraints / Assumptions
- Spotify Production access is not available; do not rely on Spotify user-auth endpoints for core functionality.
- Apple Music playlist creation should work for users with an Apple Music subscription.
- Do not ship Apple Music private keys in the app.
- Keep a service-neutral internal playlist model to support future providers (Spotify export-only, YouTube, Tidal, etc.).

## High-level Architecture

### On-device (iOS)
- **MusicKit authorization**: request Apple Music permission.
- **Music User Token**: generated on-device and stored in Keychain.
- **Storefront**: determine the user’s storefront (e.g., `us`, `gb`) for catalog queries.
- **Catalog search** (Apple Music): resolve artists and tracks using Apple Music APIs.
- **Playlist creation** (Apple Music): create a library playlist and add tracks.

### Backend (minimal)
- Provide an endpoint to mint **Apple Music Developer Token (JWT)**.
  - The JWT is signed with the Apple Music private key.
  - The iOS app uses it to obtain a Music User Token.
- Optional: logging/telemetry to diagnose match failures (avoid storing personal data).

## Exact Apple Music REST API Endpoints (Apple Music API)

Base: `https://api.music.apple.com`

Auth headers (REST calls):
- `Authorization: Bearer <DEVELOPER_TOKEN_JWT>`
- `Music-User-Token: <MUSIC_USER_TOKEN>` (required for `/v1/me/...` library endpoints)

### Storefront
- Get user storefront (recommended): `GET /v1/me/storefront`
  - Use the first returned storefront’s `id` (commonly `us`, `gb`, etc.)

### Catalog search (primary track source)
- Search catalog: `GET /v1/catalog/{storefront}/search?term={term}&types=songs,artists&limit={n}`
  - Use for artist resolution and song resolution.

Optional catalog helpers (if used by your strategy):
- Artist top songs: `GET /v1/catalog/{storefront}/artists/{id}/view/top-songs`
- Artist relationships (varies by API surface; treat as optional and feature-flag):
  - `GET /v1/catalog/{storefront}/artists/{id}/relationships/songs`

### User library playlist creation
- Create playlist: `POST /v1/me/library/playlists`
  - Body (JSON API style):
    - `data.type = "libraryPlaylists"`
    - `data.attributes.name`, `data.attributes.description`
    - (Option A) include tracks relationship in the create request if supported by your implementation
- Add tracks: `POST /v1/me/library/playlists/{libraryPlaylistId}/tracks`
  - Body: `data: [{ "id": "<songId>", "type": "songs" }, ...]`
  - Chunk requests to stay within practical limits (e.g., 100 at a time).

### Notes on IDs
- Catalog song IDs are used with type `songs`.
- The playlist returned from `/v1/me/library/playlists` is a **library** playlist identifier (not a catalog playlist).

## iOS APIs to Use (MusicKit + fallback)

### Permission / entitlement
- Enable the **MusicKit** capability in the iOS target.
- Request user permission at runtime.

### Authorization
Preferred (MusicKit):
- `MusicAuthorization.request()` to request access.
- `MusicAuthorization.currentStatus` to check status.

### Developer Token and Music User Token
You need both tokens:
- **Developer Token**: minted by your backend (JWT signed with your Apple Music private key).
- **Music User Token**: generated on-device using the Developer Token.

Implementation options:
1) Use MusicKit token provider APIs (preferred when available on your minimum iOS version).
2) Fallback to StoreKit’s cloud service controller APIs (widely supported):
   - `SKCloudServiceController().requestUserToken(forDeveloperToken:completionHandler:)`
   - `SKCloudServiceController().requestStorefrontIdentifier(completionHandler:)`

Recommendation:
- Use MusicKit for authorization, and StoreKit for user token/storefront retrieval if MusicKit token APIs aren’t available on your deployment target.

## Minimal Backend JWT Service Spec (Developer Token)

### Endpoint
- `GET /apple-music/developer-token`

### Response
- `200 OK` JSON:
  - `{ "token": "<JWT>", "expiresAt": "2026-01-31T00:00:00Z" }`

### JWT Requirements (Apple Music Developer Token)
- Algorithm: **ES256**
- Header:
  - `alg`: `ES256`
  - `kid`: your Apple Music key id
- Claims:
  - `iss`: Apple Developer Team ID
  - `iat`: issued-at (unix seconds)
  - `exp`: expiration (unix seconds)

Operational guidance:
- Do **not** generate the JWT on-device.
- Cache the token server-side and rotate on a schedule (Apple allows long-lived tokens; choose a shorter lifetime operationally).
- Consider protecting the endpoint (basic rate limits; optional app attestation later).

### Security / privacy
- Backend stores:
  - Apple Music private key (server secret)
- App stores:
  - Music User Token (Keychain)
- Avoid logging Music User Tokens.

## Work Breakdown

### 1) Introduce service-neutral domain models
**Goal:** represent “playlist intent” without Spotify/Apple specifics.

- Add a `TrackDescriptor` model in `ios/Sources/DomainKit`:
  - `title`, `artistNames`, optional `albumTitle`, optional `durationMs`
  - optional `isrc`
  - optional provider IDs: `appleMusicSongID`, `spotifyTrackID`, etc.
- Add a `PlaylistDraft` model:
  - `name`, `description`, ordered `tracks: [TrackDescriptor]`

**Why:** makes Apple Music (and later other services) pluggable.

### 2) Add Apple Music client layer
**Goal:** encapsulate Apple Music API interactions.

- Create `AppleMusicAPIKit` module or add to existing `SpotifyAPIKit` as a separate client (recommended: separate module for clarity).
- Implement:
  - `AppleMusicDeveloperTokenProviding` (calls your backend)
  - `AppleMusicUserTokenStore` (Keychain)
  - `AppleMusicStorefrontProviding` (fetch storefront)
  - `AppleMusicCatalogSearching`:
    - `searchArtists(query, limit)`
    - `searchSongs(query, limit)`
    - (optional) `songsByISRC(isrc)` if supported by the API version you target
  - `AppleMusicPlaylistEditing`:
    - `createPlaylist(name, description)`
    - `addTracks(playlistID, songIDs)`

Concrete mapping of protocol methods to REST endpoints:
- `AppleMusicStorefrontProviding.storefront()` → `GET /v1/me/storefront`
- `AppleMusicCatalogSearching.searchArtists` → `GET /v1/catalog/{storefront}/search` with `types=artists`
- `AppleMusicCatalogSearching.searchSongs` → `GET /v1/catalog/{storefront}/search` with `types=songs`
- `AppleMusicCatalogSearching.topSongs(forArtistID:)` (optional) → `GET /v1/catalog/{storefront}/artists/{id}/view/top-songs`
- `AppleMusicPlaylistEditing.createPlaylist` → `POST /v1/me/library/playlists`
- `AppleMusicPlaylistEditing.addTracks` → `POST /v1/me/library/playlists/{id}/tracks`

### 3) Implement Apple Music authentication UX
**Goal:** replace “Spotify Sign In” as the primary connect flow.

- Update the authentication step to:
  - request `MusicAuthorization`
  - retrieve developer token from backend
  - generate/store music user token
  - show “Connected” state

**Notes:** Users without Apple Music subscription should get a clear message.

### 4) Replace track sourcing with Apple Music catalog
**Goal:** when building a playlist, source tracks from Apple Music rather than Spotify.

Current Spotify flow (conceptual):
- resolve artists → fetch top tracks per artist → dedupe/shuffle → create playlist

New Apple Music flow:
- resolve artists in Apple Music catalog
- for each artist:
  - choose a track sourcing strategy:
    - strategy A: top songs (if Apple Music API supports artist top songs)
    - strategy B: catalog search: query `artistName` and filter results by artist match
    - strategy C: use Apple Music “songs” relationship for artist (if available)
- build `TrackDescriptor` list with Apple Music song IDs
- run dedupe/shuffle logic on canonical descriptors

**Matching rules:**
- Prefer exact match on artist name (normalized) + track title.
- Use duration (when available) to break ties.
- Store and reuse resolved Apple Music IDs to avoid re-searching.

### 5) Implement Apple Music playlist creation
**Goal:** write playlist into the user’s Apple Music library.

- Create playlist
- Add tracks in chunks (respect API limits)
- Present success UI with “Open in Music” deep link

### 6) Keep Spotify as optional (export-only) (later)
**Goal:** preserve some Spotify value without requiring Spotify Production.

- Export formats:
  - plain text `Artist — Title`
  - CSV with artist/title/(optional ISRC)
  - JSON `PlaylistDraft`

### 7) Update UI copy and localization
- Rename the flow from Spotify to Apple Music.
- Add localized strings for:
  - “Connect Apple Music”
  - “Requires Apple Music subscription”
  - Match failures: “Some tracks could not be found”

### 8) Testing strategy
- Unit tests:
  - normalization/matching heuristics
  - dedupe/shuffle stability
  - chunking and request building
- Integration testing (manual):
  - Apple Music auth on device
  - playlist creation + adding tracks

## Milestones
1. Canonical models + Apple Music auth stubbed (no playlist creation yet)
2. Catalog search resolves artists + tracks reliably
3. Playlist creation works end-to-end on Apple Music
4. Polish: error messaging, partial match handling, export-only fallback

## Open Questions
- Which Apple Music API surface will be used:
  - MusicKit for auth + Apple Music REST API for catalog/library operations (recommended), vs attempting to use MusicKit-only requests where possible.
- Track sourcing strategy preference:
  - “Top songs” vs search-based vs artist relationships
- Do we want to maintain the existing “manual artist input + DJ AI” flow unchanged, or adapt it to Apple Music artist IDs?

## Appendix: Suggested Track Sourcing Strategy (Apple-first)

To replace Spotify “top tracks per artist”, start with this deterministic approach:
1) Resolve artists by name using catalog search (`types=artists`) and pick best match.
2) For each resolved artist:
   - Try `view/top-songs` first.
   - If unavailable/empty, run `types=songs` search with term `"<artist> <seed genre or prompt keyword>"` and filter by artist match.
3) Accumulate songs until `limitPerArtist` is met; then apply existing dedupe/shuffle.

This yields stable output and avoids relying on undocumented relationships.
