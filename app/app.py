"""Kivy application bootstrap for Spotify playlist automation."""

from __future__ import annotations

from pathlib import Path
from typing import Optional

from kivy.app import App
from kivy.clock import Clock
from kivy.lang import Builder
from kivy.uix.screenmanager import Screen, ScreenManager
from app.controllers.auth_controller import AuthController
from app.controllers.playlist_controller import PlaylistController

from app.state.app_state import AppState
from config.settings import settings

KV_FILE = Path(__file__).parent / "ui" / "main.kv"


class RootScreen(Screen):
    """Root screen that wires UI callbacks into application logic."""

    _refresh_event = None

    def on_kv_post(self, base_widget):  # type: ignore[override]
        super().on_kv_post(base_widget)
        self._apply_playlist_defaults()
        self._schedule_refresh()
        self._sync_state(0)

    # ------------------------------------------------------------------
    # UI callbacks

    def on_auth_button_press(self) -> None:
        app = self._app
        if self._state.is_authenticated:
            app.auth_controller.sign_out()
        else:
            app.auth_controller.sign_in()

    def update_playlist_name(self, value: str) -> None:
        new_value = value.strip() or "Untitled Playlist"
        self._state.playlist_options.playlist_name = new_value
        name_input = self.ids.get("playlist_name_input")
        if name_input is not None:
            name_input.text = new_value

    def update_numeric_option(self, option: str, value: str) -> None:
        cleaned = value.strip()
        if not cleaned:
            return
        try:
            number = max(0, int(cleaned))
        except ValueError:
            return
        setattr(self._state.playlist_options, option, number)

    def update_boolean_option(self, option: str, active: bool) -> None:
        setattr(self._state.playlist_options, option, active)
        if option == "shuffle":
            shuffle_seed_input = self.ids.get("shuffle_seed_input")
            if shuffle_seed_input is not None:
                shuffle_seed_input.disabled = not active
                if not active:
                    shuffle_seed_input.text = ""
                    self._state.playlist_options.shuffle_seed = None

    def update_shuffle_seed(self, value: str) -> None:
        cleaned = value.strip()
        if not cleaned:
            self._state.playlist_options.shuffle_seed = None
            return
        try:
            self._state.playlist_options.shuffle_seed = int(cleaned)
        except ValueError:
            self._state.playlist_options.shuffle_seed = None

    def update_artists_file(self, value: str) -> None:
        cleaned = value.strip()
        self._state.playlist_options.artists_file = cleaned or None

    def trigger_build(self, dry_run: bool) -> None:
        controller = self._app.playlist_controller
        if controller is not None:
            controller.build_playlist(dry_run=dry_run)

    def open_latest_playlist(self) -> None:
        url = self._state.last_playlist_url
        if url:
            import webbrowser

            webbrowser.open(url)

    # ------------------------------------------------------------------
    # Internal helpers

    def _schedule_refresh(self) -> None:
        if self._refresh_event is None:
            self._refresh_event = Clock.schedule_interval(
                self._sync_state,
                0.5,
            )

    def _sync_state(self, _dt: float) -> None:
        state = self._state
        ids = self.ids
        auth_label = ids.get("auth_status_label")
        if auth_label is not None:
            status_parts = [state.auth_status]
            if state.auth_error:
                status_parts.append(f"Error: {state.auth_error}")
            auth_label.text = "\n".join(status_parts)
        button = ids.get("auth_button")
        if button is not None:
            button.text = "Sign out" if state.is_authenticated else "Sign in"
            button.disabled = state.is_authenticating
        scope_label = ids.get("scope_label")
        if scope_label is not None:
            scope_label.text = (
                f"Scopes: {state.granted_scope}" if state.granted_scope else ""
            )
        build_label = ids.get("build_status_label")
        if build_label is not None:
            status_parts = [state.build_status]
            if state.build_error:
                status_parts.append(f"Error: {state.build_error}")
            build_label.text = "\n".join(status_parts)
        details_label = ids.get("build_details_label")
        if details_label is not None:
            result = state.last_result
            if result is None:
                details_label.text = ""
            else:
                details = [
                    f"Playlist: {result.playlist_name}",
                    f"Prepared: {len(result.prepared_track_uris)}",
                ]
                if result.dry_run:
                    details.append("Dry run")
                else:
                    details.append(
                        f"Uploaded: {len(result.added_track_uris)}"
                    )
                if result.reused_existing:
                    details.append("Reused existing playlist")
                details_label.text = " | ".join(details)
        open_button = ids.get("open_playlist_button")
        if open_button is not None:
            open_button.disabled = not bool(state.last_playlist_url)
        dry_run_button = ids.get("dry_run_button")
        if dry_run_button is not None:
            dry_run_button.disabled = (
                not state.is_authenticated
                or state.is_authenticating
                or state.is_building_playlist
            )
        build_button = ids.get("build_button")
        if build_button is not None:
            build_button.disabled = (
                not state.is_authenticated
                or state.is_authenticating
                or state.is_building_playlist
            )

    def _apply_playlist_defaults(self) -> None:
        options = self._state.playlist_options
        ids = self.ids
        mapping = {
            "playlist_name_input": options.playlist_name,
            "limit_per_artist_input": str(options.limit_per_artist),
            "max_artists_input": str(options.max_artists),
            "max_tracks_input": str(options.max_tracks),
            "shuffle_seed_input": (
                ""
                if options.shuffle_seed is None
                else str(options.shuffle_seed)
            ),
            "artists_file_input": options.artists_file or "",
        }
        for widget_id, value in mapping.items():
            widget = ids.get(widget_id)
            if widget is not None:
                widget.text = value
        boolean_mapping = {
            "date_stamp_checkbox": options.date_stamp,
            "dedupe_checkbox": options.dedupe_variants,
            "print_checkbox": options.print_tracks,
            "shuffle_checkbox": options.shuffle,
            "reuse_checkbox": options.reuse_existing,
            "truncate_checkbox": options.truncate,
            "dry_run_checkbox": options.dry_run,
            "verbose_checkbox": options.verbose,
            "library_checkbox": options.library_artists,
        }
        for widget_id, active in boolean_mapping.items():
            widget = ids.get(widget_id)
            if widget is not None:
                widget.active = active
        shuffle_seed_input = ids.get("shuffle_seed_input")
        if shuffle_seed_input is not None:
            shuffle_seed_input.disabled = not options.shuffle

    @property
    def _app(self) -> "SpotifyPlaylistApp":
        return App.get_running_app()  # type: ignore[return-value]

    @property
    def _state(self) -> AppState:
        return self._app.state


class RootScreenManager(ScreenManager):
    """Single-screen manager kept for future navigation expansion."""


class SpotifyPlaylistApp(App):
    """Main Kivy application class."""

    title = "Spotify Playlist Automation"

    def __init__(self, **kwargs):  # type: ignore[no-untyped-def]
        super().__init__(**kwargs)
        self._state: Optional[AppState] = None
        self.auth_controller: Optional[AuthController] = None
        self.playlist_controller: Optional[PlaylistController] = None

    def build(self):  # type: ignore[override]
        """Load KV layout and construct the root widget."""
        self._state = AppState.from_settings(settings)
        self.auth_controller = AuthController(self)
        self.playlist_controller = PlaylistController(self)
        Builder.load_file(str(KV_FILE))
        manager = RootScreenManager()
        manager.add_widget(RootScreen(name="home"))
        return manager

    @property
    def state(self) -> AppState:
        """Return the lazily-created app state."""
        if self._state is None:
            self._state = AppState.from_settings(settings)
        return self._state
