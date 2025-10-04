"""Build a YouTube Music playlist from a list of artist names."""

from __future__ import annotations

import argparse
import json
import os
import sys
from getpass import getpass
from pathlib import Path
from typing import List, Tuple

try:
    from config.settings import settings
except ModuleNotFoundError:  # pragma: no cover - fallback for direct execution
    PROJECT_ROOT = Path(__file__).resolve().parents[1]
    if str(PROJECT_ROOT) not in sys.path:
        sys.path.insert(0, str(PROJECT_ROOT))
    from config.settings import settings

from core.music_service import MusicService
from core.playlist_builder import PlaylistBuilderError
from core.playlist_options import PlaylistOptions
from core.ytmusic_playlist_builder import YTMusicPlaylistBuilder
from services.ytmusic_client import YTMusicClient, YTMusicClientError


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description=(
            "Create a YouTube Music playlist using top tracks from a list of "
            "artists."
        )
    )
    parser.add_argument(
        "--artists-file",
        help="Path to a text file containing artist names (one per line).",
    )
    parser.add_argument(
        "--playlist-name",
        help="Name of the playlist to create.",
    )
    parser.add_argument(
        "--description",
        default=None,
        help="Optional playlist description. Defaults to a generated summary.",
    )
    parser.add_argument(
        "--limit-per-artist",
        type=int,
        default=5,
        help="Maximum number of tracks to take from each artist (default: 5).",
    )
    parser.add_argument(
        "--max-tracks",
        type=int,
        default=100,
        help="Global track limit for the playlist (default: 100).",
    )
    parser.add_argument(
        "--privacy",
        choices=["PRIVATE", "PUBLIC", "UNLISTED"],
        default=None,
        help=(
            "Playlist privacy level. Defaults to the value provided via "
            "YTMUSIC_PLAYLIST_PRIVACY in the .env file."
        ),
    )
    parser.add_argument(
        "--create",
        action="store_true",
        help=(
            "If set, create the playlist. "
            "Without this flag the script performs a dry run."
        ),
    )
    parser.add_argument(
        "--setup-oauth",
        action="store_true",
        help=(
            "Run the OAuth browser flow to produce the oauth credentials "
            "file and exit."
        ),
    )
    parser.add_argument(
        "--client-id",
        help=(
            "Google OAuth client ID. Falls back to the YTMUSIC_CLIENT_ID or "
            "GOOGLE_CLIENT_ID environment variable, or prompts if omitted."
        ),
    )
    parser.add_argument(
        "--client-secret",
        help=(
            "Google OAuth client secret. Falls back to the "
            "YTMUSIC_CLIENT_SECRET or GOOGLE_CLIENT_SECRET environment "
            "variable, or prompts if omitted."
        ),
    )
    parser.add_argument(
        "--client-secrets",
        help=(
            "Path to a Google OAuth client secrets JSON file. When "
            "provided, overrides --client-id/--client-secret."
        ),
    )
    return parser.parse_args()


def resolve_client_credentials(args: argparse.Namespace) -> Tuple[str, str]:
    if args.client_secrets:
        secrets_path = Path(args.client_secrets).expanduser()
        try:
            with secrets_path.open(encoding="utf-8") as handle:
                data = json.load(handle)
        except FileNotFoundError as exc:
            raise ValueError(
                f"Client secrets file not found: {secrets_path}"
            ) from exc
        except json.JSONDecodeError as exc:
            raise ValueError(
                "Client secrets file is not valid JSON."
            ) from exc
        payload = data
        if isinstance(data, dict):
            for key in ("installed", "web"):
                if key in data and isinstance(data[key], dict):
                    payload = data[key]
                    break
        client_id = (
            payload.get("client_id") if isinstance(payload, dict) else None
        )
        client_secret = (
            payload.get("client_secret")
            if isinstance(payload, dict)
            else None
        )
        if client_id and client_secret:
            return client_id, client_secret
        raise ValueError(
            "Client secrets file is missing client_id/client_secret entries."
        )

    client_id = (
        args.client_id
        or os.getenv("YTMUSIC_CLIENT_ID")
        or os.getenv("GOOGLE_CLIENT_ID")
    )
    client_secret = (
        args.client_secret
        or os.getenv("YTMUSIC_CLIENT_SECRET")
        or os.getenv("GOOGLE_CLIENT_SECRET")
    )

    if not client_id:
        client_id = input("Google OAuth client ID: ").strip()
    if not client_secret:
        client_secret = getpass("Google OAuth client secret: ").strip()

    if not client_id or not client_secret:
        raise ValueError(
            "Client ID and secret are required to run OAuth setup."
        )

    return client_id, client_secret


def load_artists(file_path: Path) -> List[str]:
    if not file_path.exists():
        raise FileNotFoundError(f"Artists file '{file_path}' does not exist")
    artists: List[str] = []
    for line in file_path.read_text(encoding="utf-8").splitlines():
        cleaned = line.strip()
        if not cleaned or cleaned.startswith("#"):
            continue
        artists.append(cleaned)
    return artists


def main() -> int:
    args = parse_args()

    oauth_path = settings.ytmusic_oauth_path
    if args.setup_oauth:
        try:
            client_id, client_secret = resolve_client_credentials(args)
            target = YTMusicClient.bootstrap_oauth(
                oauth_path,
                client_id=client_id,
                client_secret=client_secret,
                open_browser=True,
            )
        except Exception as error:  # pylint: disable=broad-except
            print(
                f"Failed to complete YouTube OAuth setup: {error}",
                file=sys.stderr,
            )
            return 1
        else:
            print(f"OAuth credentials saved to {target}")
            return 0

    if not args.artists_file or not args.playlist_name:
        print(
            "--artists-file and --playlist-name are required unless running "
            "with --setup-oauth",
            file=sys.stderr,
        )
        return 2

    privacy = args.privacy or settings.ytmusic_playlist_privacy

    try:
        client = YTMusicClient(oauth_path)
    except YTMusicClientError as error:
        print(
            (
                f"{error}. Run this script with --setup-oauth to initialise "
                "credentials."
            ),
            file=sys.stderr,
        )
        return 1

    artists = load_artists(Path(args.artists_file).expanduser())
    if not artists:
        print("No artists provided. Nothing to do.", file=sys.stderr)
        return 1

    options = PlaylistOptions.from_settings(settings)
    options.music_service = MusicService.YTMUSIC
    options.library_artists = False
    options.followed_artists = False
    options.reuse_existing = False
    options.truncate = False
    options.playlist_name = args.playlist_name
    options.playlist_description = args.description or None
    options.manual_artist_queries = artists
    options.artists_file = None
    options.limit_per_artist = max(0, args.limit_per_artist)
    options.max_tracks = max(0, args.max_tracks)
    options.dry_run = not args.create

    builder = YTMusicPlaylistBuilder(client, privacy=privacy)

    try:
        result = builder.build(options)
    except (YTMusicClientError, PlaylistBuilderError) as error:
        print(f"Failed to build playlist: {error}", file=sys.stderr)
        return 1
    finally:
        client.close()

    for line in result.display_tracks:
        print(line)

    stats_lines = result.stats.lines()
    if stats_lines:
        print("\nBuild stats:")
        for line in stats_lines:
            print(f"  {line}")

    if options.dry_run:
        print(
            "\nDry run complete. Re-run with --create to build the playlist."
        )
        return 0

    url = (
        YTMusicClient.playlist_url(result.playlist_id)
        if result.playlist_id
        else "(unavailable)"
    )
    print(
        "\nPlaylist created successfully:\n"
        f"  Name: {result.playlist_name}\n"
        f"  Tracks added: {len(result.added_track_uris)}\n"
        f"  URL: {url}"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
