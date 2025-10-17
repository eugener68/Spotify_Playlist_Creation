"""Environment-driven configuration values."""

from __future__ import annotations

from dataclasses import dataclass
from pathlib import Path
import os
import sys
from typing import List

from dotenv import load_dotenv


def _load_env_files() -> None:
    candidates = []

    candidates.append(Path.cwd() / ".env")

    project_root = Path(__file__).resolve().parents[1]
    candidates.append(project_root / ".env")

    try:
        executable = Path(sys.executable).resolve()
        resources_dir = executable.parent.parent / "Resources"
        candidates.append(resources_dir / ".env")
    except Exception:  # pragma: no cover - defensive
        pass

    bundle_dir = getattr(sys, "_MEIPASS", None)
    if bundle_dir:
        candidates.append(Path(bundle_dir) / ".env")

    for path in candidates:
        try:
            if path.is_file():
                load_dotenv(path, override=False)
        except Exception:  # pragma: no cover - defensive
            continue


_load_env_files()

# Debug helper: if user wants to verify env loading before Settings is built.
_raw_client_id = os.getenv("SPOTIFY_CLIENT_ID", "")
if _raw_client_id:
    masked = _raw_client_id[:6] + "..." if len(_raw_client_id) > 6 else _raw_client_id
    # Avoid importing logging globally here; print is fine this early.
    print(f"[config] Detected SPOTIFY_CLIENT_ID (masked): {masked}")
else:
    print("[config] SPOTIFY_CLIENT_ID not present in environment at import time")


REQUIRED_SCOPES = (
    "playlist-modify-private",
    "playlist-modify-public",
    "user-top-read",
    "user-follow-read",
)

_DEFAULT_SCOPE_STRING = ",".join(REQUIRED_SCOPES)


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

    @classmethod
    def from_env(cls) -> "Settings":
        """Load configuration from environment variables."""
        client_id = os.getenv("SPOTIFY_CLIENT_ID", "")
        # Treat common placeholder values as missing so the UI shows a clear error
        placeholder_ids = {
            "your_spotify_client_id",
            "<your_client_id>",
            "spotify_client_id_here",
        }
        if client_id.strip().lower() in placeholder_ids:
            client_id = ""
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
        return cls(
            client_id=client_id,
            scopes=scopes,
            redirect_port=redirect_port,
            default_playlist_name=default_playlist_name,
            default_limit_per_artist=default_limit_per_artist,
            default_max_artists=default_max_artists,
            default_max_tracks=default_max_tracks,
            default_verbose=default_verbose,
        )


settings = Settings.from_env()
