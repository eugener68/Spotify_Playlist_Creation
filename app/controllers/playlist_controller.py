"""Controller that orchestrates playlist builds on a worker thread."""

from __future__ import annotations

import copy
import threading
from typing import Optional

from kivy.app import App
from kivy.clock import Clock

from app.state.app_state import AppState
from core.playlist_builder import (
    PlaylistBuilder,
    PlaylistBuilderError,
    PlaylistResult,
)
from core.playlist_options import PlaylistOptions
from services.spotify_client import SpotifyClient, SpotifyClientError


class PlaylistController:
    """Coordinates playlist automation requests from the UI."""

    def __init__(self, app: App):
        self._app = app
        self._lock = threading.Lock()
        self._thread: Optional[threading.Thread] = None

    @property
    def state(self) -> AppState:
        return self._app.state  # type: ignore[attr-defined]

    def build_playlist(self, *, dry_run: bool) -> None:
        """Kick off a playlist build or dry run."""
        with self._lock:
            if self.state.is_building_playlist:
                return
            if not self.state.is_authenticated or not self.state.access_token:
                self.state.mark_build_failure(
                    "Sign in to Spotify before building a playlist."
                )
                return
            options = copy.deepcopy(self.state.playlist_options)
            if options.reuse_existing:
                options.target_playlist_id = None
                last_result = self.state.last_result
                if last_result and last_result.playlist_id:
                    desired = options.playlist_name.strip().lower()
                    existing_name = (last_result.playlist_name or "").strip().lower()
                    if existing_name == desired or existing_name.startswith(f"{desired} "):
                        options.target_playlist_id = last_result.playlist_id
            options.dry_run = dry_run
            message = (
                "Performing dry run..."
                if options.dry_run
                else "Building playlist..."
            )
            self.state.mark_build_started(message)
            token = self.state.access_token
            thread = threading.Thread(
                target=self._run_build,
                args=(options, token),
                daemon=True,
            )
            self._thread = thread
            thread.start()

    # ------------------------------------------------------------------
    # Internal helpers

    def _run_build(
        self,
        options: PlaylistOptions,
        token: Optional[str],
    ) -> None:
        client: Optional[SpotifyClient] = None
        try:
            if not token:
                raise PlaylistBuilderError(
                    "Access token missing. Please sign in again."
                )
            client = SpotifyClient(token)
            builder = PlaylistBuilder(client)
            result = builder.build(options)
            playlist_url = self._build_playlist_url(result)
            printed_tracks = (
                result.display_tracks if options.print_tracks else []
            )
            if options.print_tracks:
                for line in printed_tracks:
                    print(line)
            Clock.schedule_once(
                lambda _dt: self._on_success(
                    result,
                    playlist_url,
                    printed_tracks,
                )
            )
        except (SpotifyClientError, PlaylistBuilderError) as error:
            message = str(error)
            Clock.schedule_once(
                lambda _dt: self.state.mark_build_failure(message)
            )
        except Exception as error:  # pylint: disable=broad-except
            message = str(error)
            Clock.schedule_once(
                lambda _dt: self.state.mark_build_failure(message)
            )
        finally:
            if client is not None:
                client.close()
            with self._lock:
                self._thread = None

    def _on_success(
        self,
        result: PlaylistResult,
        playlist_url: Optional[str],
        printed_tracks,
    ) -> None:
        self.state.mark_build_success(
            result,
            playlist_url,
            list(printed_tracks),
        )
        stats_lines = result.stats.lines()
        app = self._app
        if stats_lines and hasattr(app, "show_build_stats_popup"):
            app.show_build_stats_popup(stats_lines)

    @staticmethod
    def _build_playlist_url(result: PlaylistResult) -> Optional[str]:
        if not result.playlist_id:
            return None
        return f"https://open.spotify.com/playlist/{result.playlist_id}"
