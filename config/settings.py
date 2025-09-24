"""Environment-driven configuration values."""

from __future__ import annotations

from dataclasses import dataclass
import os
from typing import List

from dotenv import load_dotenv

load_dotenv()


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

    @classmethod
    def from_env(cls) -> "Settings":
        """Load configuration from environment variables."""
        client_id = os.getenv("SPOTIFY_CLIENT_ID", "")
        scopes = [
            scope.strip()
            for scope in os.getenv(
                "SPOTIFY_SCOPES",
                "playlist-modify-private,playlist-modify-public,user-top-read",
            ).split(",")
            if scope.strip()
        ]
        redirect_port = int(os.getenv("SPOTIFY_REDIRECT_PORT", "8765"))
        default_playlist_name = os.getenv(
            "DEFAULT_PLAYLIST_NAME",
            "Fav Artists Top Tracks",
        )
        default_limit_per_artist = int(
            os.getenv("DEFAULT_LIMIT_PER_ARTIST", "5")
        )
        default_max_artists = int(
            os.getenv("DEFAULT_MAX_ARTISTS", "50")
        )
        default_max_tracks = int(
            os.getenv("DEFAULT_MAX_TRACKS", "250")
        )
        return cls(
            client_id=client_id,
            scopes=scopes,
            redirect_port=redirect_port,
            default_playlist_name=default_playlist_name,
            default_limit_per_artist=default_limit_per_artist,
            default_max_artists=default_max_artists,
            default_max_tracks=default_max_tracks,
        )


settings = Settings.from_env()
