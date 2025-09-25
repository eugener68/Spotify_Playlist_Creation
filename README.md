# Spotify Playlist Creation

Automate playlist creation for Spotify based on artist lists or your library/followed artists.

## Required Spotify scopes

The app needs the following scopes when you authenticate with Spotify:

- `playlist-modify-private`
- `playlist-modify-public`
- `user-top-read`
- `user-follow-read`

Set the `SPOTIFY_SCOPES` environment variable to the comma-separated list above (or leave it unset to use the defaults). After changing scopes, sign out in the app and sign back in so Spotify issues a token with the new permissions.

## Packaging

### Windows & macOS executables (PyInstaller)

This repository now ships with a shared PyInstaller spec (`packaging/AutoPlaylistBuilder.spec`) and helper scripts that bundle the Kivy UI and default configuration automatically.

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

   - **macOS (zsh/bash):** run the script on a Mac host with a working Python 3 + Kivy toolchain (you can make it executable once via `chmod +x scripts/build-macos.sh`):

     ```bash
     ./scripts/build-macos.sh
     ```

       Add `--clean` to force a fresh build, or point to a different interpreter with `--python /full/path/to/python`. Any other arguments are passed straight to PyInstaller.

   Both scripts invoke PyInstaller with the shared spec, include `app/ui/main.kv` and `config/settings.py`, and request the correct SDL/GLEW backends for each OS.

3. **Distribute the bundle** located in `dist/AutoPlaylistBuilder/`. Copy your `.env` into that folder (or adjust baked defaults in `config/settings.py`) before sharing the build.
4. **Optional macOS signing:** For public releases, sign and notarise the app (`codesign --deep --force --sign ...` followed by `xcrun notarytool submit`). Skip this step for personal testing.

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
