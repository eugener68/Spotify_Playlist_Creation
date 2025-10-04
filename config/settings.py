"""Environment-driven configuration values."""

from __future__ import annotations

from dataclasses import dataclass
import os
from pathlib import Path
from typing import List

from dotenv import load_dotenv

load_dotenv()


REQUIRED_SCOPES = (
    "playlist-modify-private",
    "playlist-modify-public",
    "user-top-read",
    "user-follow-read",
)

_DEFAULT_SCOPE_STRING = ",".join(REQUIRED_SCOPES)

_PROJECT_ROOT = Path(__file__).resolve().parent.parent
_DEFAULT_YTMUSIC_OAUTH_PATH = str(_PROJECT_ROOT / "ytmusic_oauth.json")
_DEFAULT_MUSIC_SERVICE = "SPOTIFY"

_DEFAULT_YTMUSIC_PRIVACY = "PRIVATE"


@dataclass(frozen=True)
class Settings:
    """Immutable settings resolved from environment variables."""

    client_id: str
    scopes: List[str]
    redirect_port: int
    default_playlist_name: str
    default_limit_per_artist: int
    default_max_artists: int
    default_max_tracks: int
    default_verbose: bool
    ytmusic_oauth_path: str
    ytmusic_playlist_privacy: str
    default_music_service: str
    ytmusic_client_id: str
    ytmusic_client_secret: str

    @classmethod
    def from_env(cls) -> "Settings":
        """Load configuration from environment variables."""
        client_id = os.getenv("SPOTIFY_CLIENT_ID", "")
        raw_scopes = os.getenv("SPOTIFY_SCOPES", _DEFAULT_SCOPE_STRING)
        scopes: List[str] = []
        for scope in raw_scopes.split(","):
            cleaned = scope.strip()
            if cleaned and cleaned not in scopes:
                scopes.append(cleaned)
        for required in REQUIRED_SCOPES:
            if required not in scopes:
                scopes.append(required)
        redirect_port = int(os.getenv("SPOTIFY_REDIRECT_PORT", "8765"))
        default_playlist_name = os.getenv(
            "DEFAULT_PLAYLIST_NAME",
            "Fav Artists Top Tracks",
        )
        default_limit_per_artist = int(
            os.getenv("DEFAULT_LIMIT_PER_ARTIST", "5")
        )
        default_max_artists = int(
            os.getenv("DEFAULT_MAX_ARTISTS", "100")
        )
        default_max_tracks = int(
            os.getenv("DEFAULT_MAX_TRACKS", "500")
        )
        default_verbose = (
            os.getenv("DEFAULT_VERBOSE", "false").lower() == "true"
        )
        ytmusic_oauth_path = os.path.expanduser(
            os.getenv("YTMUSIC_OAUTH_PATH", _DEFAULT_YTMUSIC_OAUTH_PATH)
        )
        ytmusic_playlist_privacy = os.getenv(
            "YTMUSIC_PLAYLIST_PRIVACY",
            _DEFAULT_YTMUSIC_PRIVACY,
        ).strip().upper()
        if ytmusic_playlist_privacy not in {"PRIVATE", "PUBLIC", "UNLISTED"}:
            ytmusic_playlist_privacy = _DEFAULT_YTMUSIC_PRIVACY
        default_music_service = os.getenv(
            "DEFAULT_MUSIC_SERVICE",
            _DEFAULT_MUSIC_SERVICE,
        ).strip().upper()
        if default_music_service not in {"SPOTIFY", "YTMUSIC"}:
            default_music_service = _DEFAULT_MUSIC_SERVICE
        ytmusic_client_id = (
            os.getenv("YTMUSIC_CLIENT_ID")
            or os.getenv("GOOGLE_CLIENT_ID")
            or ""
        ).strip()
        ytmusic_client_secret = (
            os.getenv("YTMUSIC_CLIENT_SECRET")
            or os.getenv("GOOGLE_CLIENT_SECRET")
            or ""
        ).strip()
        return cls(
            client_id=client_id,
            scopes=scopes,
            redirect_port=redirect_port,
            default_playlist_name=default_playlist_name,
            default_limit_per_artist=default_limit_per_artist,
            default_max_artists=default_max_artists,
            default_max_tracks=default_max_tracks,
            default_verbose=default_verbose,
            ytmusic_oauth_path=ytmusic_oauth_path,
            ytmusic_playlist_privacy=ytmusic_playlist_privacy,
            default_music_service=default_music_service,
            ytmusic_client_id=ytmusic_client_id,
            ytmusic_client_secret=ytmusic_client_secret,
        )


settings = Settings.from_env()
