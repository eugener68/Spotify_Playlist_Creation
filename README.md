# Spotify Playlist Creation

Automate playlist creation for Spotify based on artist lists or your library/followed artists.

> **Beta:** The desktop UI now exposes a **Music service** selector. Spotify workflows are battle-tested, and YouTube Music builds work end-to-end for manual/file-based artist lists (with a few limitations listed below).

## YouTube Music in the desktop app (beta)

- Pick **YouTube Music** from the *Music service* dropdown in the Playlist Options panel.
- Optionally supply a playlist description in the new text area; both Spotify and YouTube builds now respect it.
- The Authentication card will surface credential status. Run `scripts/ytmusic_from_artists.py --setup-oauth --client-secrets path/to/client_secret.json` once (or supply the client ID/secret when prompted) to generate the required `ytmusic_oauth.json`, then restart or switch services to refresh the status.
- The Authentication card will surface credential status. Run `scripts/ytmusic_from_artists.py --setup-oauth --client-secrets path/to/client_secret.json` once (or supply the client ID/secret when prompted) to generate the required `ytmusic_oauth.json`, then restart or switch services to refresh the status. Use a Google OAuth client of type **“TVs and Limited Input devices”**.
- Current limitations: artist sources must come from the manual list or an artists file (library/followed toggles are Spotify-only for now); playlist reuse and truncate options are disabled; OAuth setup stays external to the GUI—press the **YouTube OAuth instructions** button for a quick reminder.
- Dry runs and full builds pipe their summaries into the Build Status panel, and (optionally) echo track lists to the console when *Print tracks to console* is enabled.

## Required Spotify scopes

The app needs the following scopes when you authenticate with Spotify:

- `playlist-modify-private`
- `playlist-modify-public`
- `user-top-read`
- `user-follow-read`

Set the `SPOTIFY_SCOPES` environment variable to the comma-separated list above (or leave it unset to use the defaults). After changing scopes, sign out in the app and sign back in so Spotify issues a token with the new permissions.

## Packaging

### Windows & macOS executables (PyInstaller)

This repository now ships with platform-specific PyInstaller specs and helper scripts that bundle the Kivy UI and default configuration automatically.

1. **Install build dependencies** inside a fresh virtual environment:

   ```bash
   python -m pip install -r requirements.txt
   python -m pip install pyinstaller
   ```

2. **Run the platform-specific helper script** from the project root:

   - **Windows (PowerShell):**

     ```powershell
     ./scripts/build-windows.ps1
     ```

     Pass `-Clean` to force a fresh build (`./scripts/build-windows.ps1 -Clean`).

      Uses `packaging/AutoPlaylistBuilder.spec`, which produces the standard folder-style distribution expected on Windows.

   - **macOS (zsh/bash):** run the script on a Mac host with a working Python 3 + Kivy toolchain (you can make it executable once via `chmod +x scripts/build-macos.sh`):

     ```bash
     ./scripts/build-macos.sh
     ```

      Add `--clean` to force a fresh build, or point to a different interpreter with `--python /full/path/to/python`. Any other arguments are passed straight to PyInstaller. Append `--bundle-env` to tuck the project `.env` into `AutoPlaylistBuilder.app/Contents/Resources/.env` for self-contained distribution. This script targets `packaging/AutoPlaylistBuilder-mac.spec`, which emits a true `.app` bundle with GUI-only boot mode.

   Both scripts include `app/ui/main.kv` and `config/settings.py`, and request the correct SDL/GLEW backends for each OS.

3. **Distribute the bundle** located in `dist/AutoPlaylistBuilder/`. On Windows, copy your `.env` alongside the executable (or adjust baked defaults in `config/settings.py`). On macOS, pass `--bundle-env` during the build or manually add the file inside the generated `.app` under `Contents/Resources/.env`.
4. **Optional macOS signing:** For public releases, sign and notarise the app (`codesign --deep --force --sign ...` followed by `xcrun notarytool submit`). Skip this step for personal testing.

## YouTube Music (prototype CLI)

An experimental script in `scripts/ytmusic_from_artists.py` can assemble a YouTube Music playlist using the same artist-list workflow:

1. **Install dependencies** (this project now depends on `ytmusicapi`).
2. **Run the OAuth bootstrap** once to capture credentials (pass a Google client secrets JSON or let the script prompt for the values). Create the OAuth client as **TVs and Limited Input devices** and set `GOOGLE_CLIENT_ID` / `GOOGLE_CLIENT_SECRET` in your `.env`:

   ```bash
   python scripts/ytmusic_from_artists.py --setup-oauth --client-secrets path/to/client_secret.json
   ```

   The script opens a browser to authorise YouTube Music and stores the token at the path controlled by `YTMUSIC_OAUTH_PATH` (defaults to `ytmusic_oauth.json` in the project root).

3. **Build a dry-run playlist** from an artists text file:

   ```bash
   python scripts/ytmusic_from_artists.py --artists-file my_artists.txt --playlist-name "Test Mix"
   ```

4. **Create the playlist** for real by adding `--create`; adjust privacy with `--privacy` (defaults to the `YTMUSIC_PLAYLIST_PRIVACY` setting).

This CLI is a stepping stone toward first-class YouTube Music support in the GUI.
It now reuses the same YouTube Music playlist builder that powers the desktop
app, so stats, deduping, and shuffle behaviour stay consistent across both
entry points.

### Android APK (Buildozer)

1. Buildozer requires Linux. On Windows, run the steps below inside WSL (Ubuntu) or a Linux VM. Install prerequisites: `sudo apt update && sudo apt install python3-venv openjdk-17-jdk build-essential git unzip`. Then install Buildozer in a virtual environment: `python3 -m pip install buildozer`.
2. From the project root, initialise Buildozer: `buildozer init`. Edit the generated `buildozer.spec`:
   - Set `title = Spotify Playlist Creator` and `package.name = com.eugener68.autoplaylistbuilder`.
   - Update `source.include_exts = py,kv` so the Kivy layout ships in the APK.
   - Set `requirements = python3,kivy,requests,httpx,python-dotenv` (match `requirements.txt`).
   - Point `source.main = main.py` and ensure any environment defaults you rely on live in `config/settings.py` (Android builds cannot read `.env` files at runtime).
3. Build the debug APK: `buildozer -v android debug`. The first run downloads the Android SDK/NDK and can take a while. The resulting APK is in `bin/`.
4. For a release build, configure keystore settings in `buildozer.spec` (`android.release_keystore`, `android.release_keystore_pass`, etc.) and run `buildozer android release`. Upload the signed AAB/APK wherever you distribute it.
5. If you need to override secrets (client ID/redirect URI) at build time, add them as environment variables before invoking Buildozer or bake them into `config/settings.py`.
