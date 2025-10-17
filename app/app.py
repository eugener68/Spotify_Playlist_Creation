"""Kivy application bootstrap for Spotify playlist Builder."""

from __future__ import annotations

import re
from pathlib import Path
import sys
from typing import Optional, Sequence

from kivy.app import App
from kivy.clock import Clock
from kivy.lang import Builder
from kivy.uix.screenmanager import Screen, ScreenManager
from kivy.uix.button import Button
from kivy.uix.boxlayout import BoxLayout
from kivy.uix.label import Label
from kivy.uix.popup import Popup
from kivy.uix.filechooser import FileChooserListView
from kivy.metrics import dp
from kivy.graphics import Color, RoundedRectangle
from app.controllers.auth_controller import AuthController
from app.controllers.playlist_controller import PlaylistController

from app.state.app_state import AppState
from config.settings import settings

KV_FILE = Path(__file__).parent / "ui" / "main.kv"
ASSET_ICON = "assets/app_icon.png"


def _resolve_asset(path: str) -> Optional[str]:
    candidates = []
    base_dir = Path(__file__).resolve().parents[1]
    candidates.append(base_dir / path)

    bundle_dir = getattr(sys, "_MEIPASS", None)
    if bundle_dir:
        candidates.append(Path(bundle_dir) / path)

    try:
        executable = Path(sys.executable).resolve()
        resources_dir = executable.parent.parent / "Resources"
        candidates.append(resources_dir / path)
    except Exception:  # pragma: no cover - defensive
        pass

    for candidate in candidates:
        if candidate.is_file():
            return str(candidate)
    return None


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

    def update_manual_artists(self, value: str) -> None:
        normalized = value.replace("\r", "\n")
        pieces = [
            segment.strip().strip('"').strip("'")
            for segment in re.split(r"[\n,;]+", normalized)
        ]
        queries = [piece for piece in pieces if piece]
        self._state.playlist_options.manual_artist_queries = queries

    def browse_artists_file(self) -> None:
        """Open a file browser to select an artists file."""
        start_path = self._state.playlist_options.artists_file
        if start_path:
            initial_dir = Path(start_path).expanduser().parent
        else:
            initial_dir = Path.home()

        chooser = FileChooserListView(
            path=str(initial_dir),
            filters=["*.txt", "*.*"],
        )
        chooser.multiselect = False
        if start_path:
            chooser.selection = [str(Path(start_path).expanduser())]

        content = BoxLayout(
            orientation="vertical",
            spacing=dp(12),
            padding=dp(16),
        )
        content.add_widget(chooser)

        buttons = BoxLayout(
            orientation="horizontal",
            spacing=dp(12),
            size_hint_y=None,
            height=dp(44),
        )

        popup = Popup(
            title="Select Artists File",
            content=content,
            size_hint=(0.9, 0.9),
            auto_dismiss=False,
        )

        def _use_selection(*_args):
            if chooser.selection:
                file_path = chooser.selection[0]
                self._state.playlist_options.artists_file = file_path
                artists_file_input = self.ids.get("artists_file_input")
                if artists_file_input is not None:
                    artists_file_input.text = file_path
            popup.dismiss()

        def _cancel(*_args):
            popup.dismiss()

        use_button = Button(text="Use File")
        use_button.bind(on_release=_use_selection)
        cancel_button = Button(text="Cancel")
        cancel_button.bind(on_release=_cancel)

        buttons.add_widget(use_button)
        buttons.add_widget(cancel_button)
        content.add_widget(buttons)

        popup.open()

    def trigger_build(self, dry_run: bool) -> None:
        controller = self._app.playlist_controller
        if controller is not None:
            controller.build_playlist(dry_run=dry_run)

    def open_latest_playlist(self) -> None:
        url = self._state.last_playlist_url
        if url:
            import webbrowser

            webbrowser.open(url)

    def exit_application(self) -> None:
        """Close the application window."""
        app = App.get_running_app()
        if app is not None:
            app.stop()

    def show_build_stats_popup(self, lines: Sequence[str]) -> None:
        if not lines:
            return

        formatted_lines = [f"[b]{lines[0]}[/b]"] if lines else []
        if len(lines) > 1:
            formatted_lines.extend(lines[1:])
        text_body = "\n".join(formatted_lines)

        popup = Popup(
            title="Playlist Build Stats",
            size_hint=(None, None),
            auto_dismiss=False,
        )
        popup.width = dp(520)

        content = BoxLayout(
            orientation="vertical",
            padding=dp(22),
            spacing=dp(16),
            size_hint_y=None,
        )
        content.bind(
            minimum_height=lambda _, value: setattr(content, "height", value)
        )

        with content.canvas.before:
            Color(1, 1, 1, 1)
            bg_rect = RoundedRectangle(
                radius=[dp(12)],
                pos=content.pos,
                size=content.size,
            )

        def _sync_bg(instance, _value):
            bg_rect.pos = instance.pos
            bg_rect.size = instance.size

        content.bind(pos=_sync_bg, size=_sync_bg)

        label = Label(
            text=text_body,
            markup=True,
            color=(0.12, 0.12, 0.12, 1),
            halign="left",
            valign="top",
            size_hint_y=None,
            text_size=(popup.width - dp(80), None),
        )

        def _resize_label(instance, value):
            instance.height = value[1]

        label.bind(texture_size=_resize_label)

        close_button = Button(
            text="Close",
            size_hint_y=None,
            height=dp(44),
        )
        close_button.bind(on_release=lambda *_: popup.dismiss())

        content.add_widget(label)
        content.add_widget(close_button)
        popup.content = content

        def _update_popup_size(*_args):
            popup.height = min(
                dp(520),
                label.height + close_button.height + dp(160),
            )

        label.bind(texture_size=lambda *_: _update_popup_size())
        popup.bind(on_open=lambda *_: _update_popup_size())

        popup.open()

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
        requested_scopes = ", ".join(settings.scopes)
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
            scope_label.text = f"Requested scopes: {requested_scopes}"
        granted_scope_label = ids.get("granted_scope_label")
        if granted_scope_label is not None:
            if state.granted_scope:
                granted_scope_text = ", ".join(state.granted_scope.split())
                granted_scope_label.text = (
                    f"Granted scopes: {granted_scope_text}"
                )
            else:
                granted_scope_label.text = "Granted scopes: (pending sign-in)"
        dashboard_button = ids.get("dashboard_button")
        if dashboard_button is not None:
            dashboard_button.disabled = (
                not state.is_authenticated or state.is_authenticating
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
        stats_label = ids.get("build_stats_label")
        if stats_label is not None:
            if state.last_stats_lines:
                stats_label.text = "\n".join(state.last_stats_lines)
                stats_label.opacity = 1
            else:
                stats_label.text = ""
                stats_label.opacity = 0
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
        manual_widget = ids.get("manual_artists_input")
        if manual_widget is not None:
            manual_widget.text = "\n".join(options.manual_artist_queries)
        boolean_mapping = {
            "date_stamp_checkbox": options.date_stamp,
            "dedupe_checkbox": options.dedupe_variants,
            "print_checkbox": options.print_tracks,
            "shuffle_checkbox": options.shuffle,
            "reuse_checkbox": options.reuse_existing,
            "truncate_checkbox": options.truncate,
            "verbose_checkbox": options.verbose,
            "library_checkbox": options.library_artists,
            "followed_checkbox": options.followed_artists,
        }
        for widget_id, active in boolean_mapping.items():
            widget = ids.get(widget_id)
            if widget is not None:
                widget.active = active
        shuffle_seed_input = ids.get("shuffle_seed_input")
        if shuffle_seed_input is not None:
            shuffle_seed_input.disabled = not options.shuffle

    @property
    def _app(self) -> "AutoPlaylistBuilder":
        return App.get_running_app()  # type: ignore[return-value]

    @property
    def _state(self) -> AppState:
        return self._app.state


class RootScreenManager(ScreenManager):
    """Single-screen manager kept for future navigation expansion."""


class AutoPlaylistBuilder(App):
    """Main Kivy application class."""

    title = "Spotify Playlist Builder"

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
        icon_path = _resolve_asset(ASSET_ICON)
        if icon_path:
            self.icon = icon_path
        manager = RootScreenManager()
        manager.add_widget(RootScreen(name="home"))
        return manager

    def show_build_stats_popup(self, lines: Sequence[str]) -> None:
        root = self.root
        if root is None:
            return
        try:
            screen = root.get_screen("home")
        except Exception:  # pylint: disable=broad-except
            return
        if hasattr(screen, "show_build_stats_popup"):
            screen.show_build_stats_popup(lines)

    @property
    def state(self) -> AppState:
        """Return the lazily-created app state."""
        if self._state is None:
            self._state = AppState.from_settings(settings)
        return self._state
