"""Playlist option models mirroring the Apple Music automation flags."""

from __future__ import annotations

from dataclasses import dataclass
from typing import Optional

from config.settings import Settings


@dataclass
class PlaylistOptions:
    """Container for playlist creation preferences."""

    playlist_name: str = "Fav Artists Top Tracks"
    date_stamp: bool = False
    limit_per_artist: int = 5
    max_artists: int = 50
    max_tracks: int = 250
    dedupe_variants: bool = False
    print_tracks: bool = False
    shuffle: bool = False
    shuffle_seed: Optional[int] = None
    reuse_existing: bool = False
    truncate: bool = False
    dry_run: bool = True
    verbose: bool = False
    library_artists: bool = True
    artists_file: Optional[str] = None

    @classmethod
    def from_settings(cls, settings: Settings) -> "PlaylistOptions":
        """Seed defaults from configuration settings."""
        return cls(
            playlist_name=settings.default_playlist_name,
            limit_per_artist=settings.default_limit_per_artist,
            max_artists=settings.default_max_artists,
            max_tracks=settings.default_max_tracks,
        )
