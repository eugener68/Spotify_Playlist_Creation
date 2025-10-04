"""Application state models for the Spotify playlist builder."""

from __future__ import annotations

import json
from dataclasses import dataclass, field
from pathlib import Path
from typing import List, Optional

from config.settings import Settings
from core.playlist_builder import PlaylistResult
from core.playlist_options import PlaylistOptions


@dataclass
class AppState:
    """Aggregate runtime state shared across the UI."""

    playlist_options: PlaylistOptions = field(default_factory=PlaylistOptions)
    access_token: Optional[str] = None
    refresh_token: Optional[str] = None
    expires_at: Optional[float] = None
    is_authenticating: bool = False
    auth_status: str = "Not signed in"
    auth_error: Optional[str] = None
    user_display_name: Optional[str] = None
    granted_scope: Optional[str] = None
    ytmusic_credentials_path: Optional[str] = None
    ytmusic_auth_status: str = "YouTube Music credentials not found"
    ytmusic_credentials_ready: bool = False
    is_building_playlist: bool = False
    build_status: str = "Idle"
    build_error: Optional[str] = None
    last_result: Optional[PlaylistResult] = None
    last_playlist_url: Optional[str] = None
    last_printed_tracks: List[str] = field(default_factory=list)
    last_stats_lines: List[str] = field(default_factory=list)

    @classmethod
    def from_settings(cls, settings: Settings) -> "AppState":
        """Create a default state object from persisted settings."""
        options = PlaylistOptions.from_settings(settings)
        state = cls(playlist_options=options)
        path = settings.ytmusic_oauth_path
        state.ytmusic_credentials_path = path
        state.refresh_ytmusic_status()
        return state

    @property
    def is_authenticated(self) -> bool:
        """Return whether the user currently holds an access token."""
        return bool(self.access_token)

    def mark_auth_started(self, message: str) -> None:
        """Update state to reflect that authentication is in progress."""
        self.is_authenticating = True
        self.auth_error = None
        self.auth_status = message

    def mark_auth_success(
        self,
        *,
        access_token: str,
        refresh_token: Optional[str],
        expires_at: float,
        scope: Optional[str],
        display_name: Optional[str],
    ) -> None:
        """Persist token details and success metadata."""
        self.access_token = access_token
        self.refresh_token = refresh_token
        self.expires_at = expires_at
        self.granted_scope = scope
        self.user_display_name = display_name
        self.auth_status = (
            f"Signed in as {display_name}" if display_name else "Signed in"
        )
        self.auth_error = None

    def mark_auth_failure(self, message: str) -> None:
        """Record an authentication failure message."""
        self.auth_error = message
        self.auth_status = "Authentication failed"

    def mark_auth_finished(self) -> None:
        """Mark the end of an authentication attempt."""
        self.is_authenticating = False

    def clear_tokens(self) -> None:
        """Remove stored tokens and reset authentication details."""
        self.access_token = None
        self.refresh_token = None
        self.expires_at = None
        self.granted_scope = None
        self.user_display_name = None
        self.auth_status = "Not signed in"
        self.auth_error = None
        self.is_authenticating = False
        self.is_building_playlist = False
        self.build_status = "Idle"
        self.build_error = None
        self.last_result = None
        self.last_playlist_url = None
        self.last_printed_tracks = []
        self.last_stats_lines = []

    def refresh_ytmusic_status(self) -> None:
        """Update YouTube Music credential status."""
        path = self.ytmusic_credentials_path
        resolved = Path(path).expanduser() if path else None
        ready = False
        message = "YouTube Music credentials not found"

        if resolved and resolved.exists():
            try:
                with resolved.open(encoding="utf-8") as handle:
                    data = json.load(handle)
            except json.JSONDecodeError:
                message = "Invalid YouTube Music OAuth file (not JSON)"
            except OSError as exc:
                message = f"Unable to read OAuth file: {exc}"[:120]
            else:
                if isinstance(data, dict) and {
                    "access_token",
                    "refresh_token",
                    "scope",
                    "token_type",
                }.issubset(data.keys()):
                    ready = True
                    message = "YouTube Music credentials detected"
                else:
                    message = (
                        "OAuth client credentials found; run the OAuth flow "
                        "to generate tokens."
                    )

        self.ytmusic_credentials_ready = ready
        self.ytmusic_auth_status = message

    # ------------------------------------------------------------------
    # Playlist workflow helpers

    def mark_build_started(self, message: str) -> None:
        """Indicate that playlist processing has begun."""
        self.is_building_playlist = True
        self.build_status = message
        self.build_error = None
        self.last_stats_lines = []

    def mark_build_success(
        self,
        result: PlaylistResult,
        playlist_url: Optional[str],
        printed_tracks: List[str],
    ) -> None:
        """Persist the outcome of a successful playlist build."""
        self.is_building_playlist = False
        self.build_status = (
            "Dry run complete"
            if result.dry_run
            else "Playlist updated successfully"
        )
        self.build_error = None
        self.last_result = result
        self.last_playlist_url = playlist_url
        self.last_printed_tracks = printed_tracks
        self.last_stats_lines = result.stats.lines()

    def mark_build_failure(self, message: str) -> None:
        """Record a playlist build failure."""
        self.is_building_playlist = False
        self.build_status = "Playlist build failed"
        self.build_error = message
        self.last_stats_lines = []
