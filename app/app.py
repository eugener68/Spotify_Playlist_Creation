"""Kivy application bootstrap for Spotify playlist Builder."""

from __future__ import annotations

import re
from pathlib import Path
from typing import Optional, Sequence
import threading

from kivy.app import App
from kivy.clock import Clock
from kivy.lang import Builder
from kivy.properties import ListProperty, StringProperty
from kivy.uix.screenmanager import Screen, ScreenManager
from kivy.uix.button import Button
from kivy.uix.boxlayout import BoxLayout
from kivy.uix.label import Label
from kivy.uix.popup import Popup
from kivy.metrics import dp
from kivy.graphics import Color, RoundedRectangle
from kivy.uix.textinput import TextInput
from app.controllers.auth_controller import AuthController
from app.controllers.playlist_controller import PlaylistController
from app.state.app_state import AppState
from config.settings import settings
from core.music_service import MusicService

KV_FILE = Path(__file__).parent / "ui" / "main.kv"


class RootScreen(Screen):
    """Root screen that wires UI callbacks into application logic."""

    _refresh_event = None
    dashboard_button_text = StringProperty("Open Spotify Dashboard")
    spinner_background_color = ListProperty([0.9, 0.97, 0.92, 1])
    spinner_text_color = ListProperty([0.08, 0.33, 0.14, 1])
    spinner_dropdown_bg_color = ListProperty([0.94, 0.98, 0.95, 1])
    spinner_dropdown_highlight_color = ListProperty([0.87, 0.96, 0.90, 1])

    def on_kv_post(self, base_widget):  # type: ignore[override]
        super().on_kv_post(base_widget)
        self._apply_playlist_defaults()
        self._schedule_refresh()
        self._sync_state(0)

    # ------------------------------------------------------------------
    # UI callbacks

    def on_auth_button_press(self) -> None:
        service = self._state.playlist_options.music_service
        app = self._app
        if service == MusicService.SPOTIFY:
            if self._state.is_authenticated:
                app.auth_controller.sign_out()
            else:
                app.auth_controller.sign_in()
        else:
            self._handle_ytmusic_oauth_request()

    def update_playlist_name(self, value: str) -> None:
        new_value = value.strip() or "Untitled Playlist"
        self._state.playlist_options.playlist_name = new_value
        name_input = self.ids.get("playlist_name_input")
        if name_input is not None:
            name_input.text = new_value

    def update_playlist_description(self, value: str) -> None:
        cleaned = value.strip()
        self._state.playlist_options.playlist_description = cleaned or None

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
        try:
            import tkinter as tk
            from tkinter import filedialog
            
            # Create a temporary root window (hidden)
            root = tk.Tk()
            root.withdraw()  # Hide the root window
            root.attributes('-topmost', True)  # Bring to front
            
            # Open file dialog
            file_path = filedialog.askopenfilename(
                title="Select Artists File",
                filetypes=[("Text files", "*.txt"), ("All files", "*.*")]
            )
            root.destroy()  # Clean up
            
            if file_path:
                self._state.playlist_options.artists_file = file_path
                # Update the text input widget
                artists_file_input = self.ids.get("artists_file_input")
                if artists_file_input is not None:
                    artists_file_input.text = file_path
                    
        except ImportError:
            # Fallback if tkinter is not available - show instructions
            from kivy.uix.popup import Popup
            from kivy.uix.label import Label
            content = Label(
                text=(
                    "File Browser Not Available\n\n"
                    "Either paste artist names into the Manual artists field\n"
                    "(one name per line or separated by commas)\n"
                    "or create a text file with:\n\n"
                    "Metallica\nScorpions\nA-ha\n# Comments start with #\n\n"
                    "One artist name per line."
                ),
                text_size=(450, None),
                halign="center"
            )
            popup = Popup(
                title="Artists File Format",
                content=content,
                size_hint=(0.8, 0.7),
            )
            popup.open()

    def update_music_service(self, value: str) -> None:
        try:
            service = MusicService(value)
        except ValueError:
            service = MusicService.SPOTIFY
        options = self._state.playlist_options
        options.music_service = service
        if service == MusicService.YTMUSIC:
            options.reuse_existing = False
            options.truncate = False
            options.library_artists = False
            options.followed_artists = False
        self._state.refresh_ytmusic_status()
        self._set_spinner_palette(service)
        self._sync_state(0)

    def _handle_ytmusic_oauth_request(self) -> None:
        if self._state.is_authenticating:
            return
        if self._state.ytmusic_credentials_ready:
            self._confirm_ytmusic_oauth_refresh()
        else:
            self._show_ytmusic_oauth_dialog()

    def _show_ytmusic_oauth_dialog(self) -> None:
        message = (
            "Provide your Google YouTube Data API OAuth client credentials. "
            "When you continue, a browser window opens to complete the "
            "Google consent flow and the generated token is stored locally."
        )

        content = BoxLayout(
            orientation="vertical",
            padding=dp(20),
            spacing=dp(14),
            size_hint=(1, 1),
        )

        message_label = Label(
            text=message,
            halign="left",
            valign="top",
            text_size=(dp(440), None),
            size_hint_y=None,
        )
        message_label.bind(
            texture_size=lambda instance, value: setattr(
                instance,
                "height",
                value[1],
            )
        )

        field_box = BoxLayout(
            orientation="vertical",
            spacing=dp(10),
            size_hint_y=None,
        )

        client_label = Label(
            text="Google API Client ID",
            size_hint_y=None,
            height=dp(24),
            halign="left",
            valign="middle",
            text_size=(dp(440), None),
        )
        client_input = TextInput(
            multiline=False,
            write_tab=False,
            size_hint_y=None,
            height=dp(48),
        )

        secret_label = Label(
            text="Client Secret",
            size_hint_y=None,
            height=dp(24),
            halign="left",
            valign="middle",
            text_size=(dp(440), None),
        )
        secret_input = TextInput(
            multiline=False,
            password=True,
            write_tab=False,
            size_hint_y=None,
            height=dp(48),
        )

        field_box.bind(
            minimum_height=lambda instance, value: setattr(
                instance,
                "height",
                value,
            )
        )

        field_box.add_widget(client_label)
        field_box.add_widget(client_input)
        field_box.add_widget(secret_label)
        field_box.add_widget(secret_input)

        error_label = Label(
            text="",
            color=(0.8, 0.1, 0.1, 1),
            size_hint_y=None,
            height=dp(20),
        )

        button_row = BoxLayout(
            orientation="horizontal",
            size_hint_y=None,
            height=dp(44),
            spacing=dp(12),
        )

        popup = Popup(
            title="YouTube Music OAuth",
            content=content,
            size_hint=(0.75, None),
            height=dp(420),
        )

        def _on_cancel(_instance) -> None:
            popup.dismiss()

        def _on_start(_instance) -> None:
            client_id = client_input.text.strip()
            client_secret = secret_input.text.strip()
            if not client_id or not client_secret:
                error_label.text = (
                    "Client ID and secret are required to continue."
                )
                return
            popup.dismiss()
            self._run_ytmusic_oauth(client_id, client_secret)

        cancel_button = Button(text="Cancel")
        cancel_button.bind(on_release=_on_cancel)

        start_button = Button(text="Start OAuth")
        start_button.bind(on_release=_on_start)

        button_row.add_widget(cancel_button)
        button_row.add_widget(start_button)

        content.add_widget(message_label)
        content.add_widget(field_box)
        content.add_widget(error_label)
        content.add_widget(button_row)

        popup.open()

    def _confirm_ytmusic_oauth_refresh(self) -> None:
        info = (
            "Existing YouTube Music credentials were found. "
            "Running the OAuth flow again will overwrite them."
        )

        content = BoxLayout(
            orientation="vertical",
            padding=dp(20),
            spacing=dp(16),
            size_hint=(1, 1),
        )

        label = Label(
            text=info,
            halign="left",
            valign="top",
            text_size=(dp(420), None),
            size_hint_y=None,
        )
        label.bind(
            texture_size=lambda instance, value: setattr(
                instance,
                "height",
                value[1],
            )
        )

        button_row = BoxLayout(
            orientation="horizontal",
            size_hint_y=None,
            height=dp(44),
            spacing=dp(12),
        )

        popup = Popup(
            title="Refresh YouTube OAuth?",
            content=content,
            size_hint=(0.6, None),
            height=dp(260),
        )

        def _cancel(_instance) -> None:
            popup.dismiss()

        def _proceed(_instance) -> None:
            popup.dismiss()
            self._show_ytmusic_oauth_dialog()

        cancel_button = Button(text="Keep Existing")
        cancel_button.bind(on_release=_cancel)
        proceed_button = Button(text="Run OAuth Again")
        proceed_button.bind(on_release=_proceed)
        button_row.add_widget(cancel_button)
        button_row.add_widget(proceed_button)

        content.add_widget(label)
        content.add_widget(button_row)

        popup.open()

    def _run_ytmusic_oauth(self, client_id: str, client_secret: str) -> None:
        state = self._state
        if state.is_authenticating:
            return

        state.is_authenticating = True
        state.ytmusic_auth_status = "Launching YouTube OAuth flow..."
        self._sync_state(0)

        target_path = (
            state.ytmusic_credentials_path or settings.ytmusic_oauth_path
        )

        def _worker() -> None:
            try:
                from ytmusicapi.setup import setup_oauth as ytm_setup_oauth

                resolved = Path(target_path).expanduser()
                resolved.parent.mkdir(parents=True, exist_ok=True)
                Clock.schedule_once(
                    lambda _dt: self._set_ytmusic_status(
                        "Complete the Google consent flow in your browser."
                    ),
                    0,
                )
                ytm_setup_oauth(
                    client_id=client_id,
                    client_secret=client_secret,
                    filepath=str(resolved),
                    open_browser=True,
                )
                error: Optional[str] = None
                saved_path = resolved
            except Exception as exc:  # pylint: disable=broad-except
                error = str(exc)
                saved_path = None

            def _finish(_dt: float) -> None:
                state.is_authenticating = False
                if error:
                    state.ytmusic_auth_status = "YouTube Music OAuth failed"
                    self._show_simple_popup(
                        "YouTube OAuth Error",
                        (
                            "Failed to complete YouTube Music OAuth. "
                            f"Details: {error}"
                        ),
                    )
                else:
                    if saved_path is not None:
                        state.ytmusic_credentials_path = str(saved_path)
                    state.refresh_ytmusic_status()
                    state.ytmusic_auth_status = (
                        "YouTube Music credentials detected"
                    )
                    self._show_simple_popup(
                        "YouTube OAuth Complete",
                        (
                            "Credentials saved. You're ready to build "
                            "YouTube playlists."
                        ),
                    )
                self._sync_state(0)

            Clock.schedule_once(_finish, 0)

        threading.Thread(target=_worker, daemon=True).start()

    def _show_simple_popup(self, title: str, message: str) -> None:
        label = Label(
            text=message,
            halign="left",
            valign="top",
            text_size=(dp(420), None),
            size_hint_y=None,
        )
        label.bind(
            texture_size=lambda instance, value: setattr(
                instance,
                "height",
                value[1],
            )
        )

        content = BoxLayout(
            orientation="vertical",
            padding=dp(18),
            spacing=dp(16),
        )
        content.add_widget(label)

        button = Button(text="Close", size_hint_y=None, height=dp(44))

        popup = Popup(
            title=title,
            content=content,
            size_hint=(0.65, None),
            height=dp(320),
        )

        button.bind(on_release=lambda *_: popup.dismiss())
        content.add_widget(button)
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

    def open_dashboard(self) -> None:
        service = self._state.playlist_options.music_service
        if service == MusicService.SPOTIFY:
            url = "https://open.spotify.com"
        else:
            url = "https://music.youtube.com"
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

    def _set_spinner_palette(self, service: MusicService) -> None:
        if service == MusicService.SPOTIFY:
            self.spinner_background_color = [0.88, 0.97, 0.90, 1]
            self.spinner_text_color = [0.06, 0.31, 0.12, 1]
            self.spinner_dropdown_bg_color = [0.94, 0.98, 0.95, 1]
            self.spinner_dropdown_highlight_color = [0.84, 0.94, 0.88, 1]
        else:
            self.spinner_background_color = [1.0, 0.94, 0.94, 1]
            self.spinner_text_color = [0.55, 0.09, 0.09, 1]
            self.spinner_dropdown_bg_color = [1.0, 0.96, 0.96, 1]
            self.spinner_dropdown_highlight_color = [0.96, 0.90, 0.90, 1]

        spinner = self.ids.get("music_service_spinner")
        if spinner is not None:
            spinner.color = self.spinner_text_color
            spinner.background_color = self.spinner_background_color
            dropdown = getattr(spinner, "dropdown", None)
            if dropdown is not None:
                container = getattr(dropdown, "container", None)
                if container is not None:
                    for option in container.children:
                        try:
                            option.color = self.spinner_text_color
                            option.background_color = (0, 0, 0, 0)
                        except AttributeError:
                            continue

    def _set_ytmusic_status(self, message: str) -> None:
        state = self._state
        state.ytmusic_auth_status = message
        self._sync_state(0)

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
        service = state.playlist_options.music_service
        if service == MusicService.YTMUSIC:
            state.refresh_ytmusic_status()
        self._set_spinner_palette(service)
        options = state.playlist_options
        auth_label = ids.get("auth_status_label")
        if auth_label is not None:
            if service == MusicService.SPOTIFY:
                status_parts = [state.auth_status]
                if state.auth_error:
                    status_parts.append(f"Error: {state.auth_error}")
                auth_label.text = "\n".join(status_parts)
            else:
                auth_label.text = state.ytmusic_auth_status
        button = ids.get("auth_button")
        if button is not None:
            if service == MusicService.SPOTIFY:
                button.text = (
                    "Sign out" if state.is_authenticated else "Sign in"
                )
                button.disabled = state.is_authenticating
            else:
                button.text = (
                    "Refresh YouTube OAuth"
                    if state.ytmusic_credentials_ready
                    else "Run YouTube OAuth"
                )
                button.disabled = state.is_authenticating
        scope_label = ids.get("scope_label")
        if scope_label is not None:
            scope_label.text = (
                f"Requested scopes: {requested_scopes}"
                if service == MusicService.SPOTIFY
                else ""
            )
        granted_scope_label = ids.get("granted_scope_label")
        if granted_scope_label is not None:
            if service == MusicService.SPOTIFY:
                if state.granted_scope:
                    granted_scope_text = ", ".join(state.granted_scope.split())
                    granted_scope_label.text = (
                        f"Granted scopes: {granted_scope_text}"
                    )
                else:
                    granted_scope_label.text = (
                        "Granted scopes: (pending sign-in)"
                    )
            else:
                granted_scope_label.text = ""
        self.dashboard_button_text = (
            "Open Spotify Dashboard"
            if service == MusicService.SPOTIFY
            else "Open YouTube Music Dashboard"
        )
        dashboard_button = ids.get("dashboard_button")
        if dashboard_button is not None:
            dashboard_button.disabled = False
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
            allow_spotify = (
                service == MusicService.SPOTIFY
                and state.is_authenticated
                and not state.is_authenticating
            )
            allow_ytmusic = (
                service == MusicService.YTMUSIC
                and state.ytmusic_credentials_ready
                and not state.is_authenticating
            )
            dry_run_button.disabled = (
                not (allow_spotify or allow_ytmusic)
                or state.is_building_playlist
            )
        build_button = ids.get("build_button")
        if build_button is not None:
            allow_spotify = (
                service == MusicService.SPOTIFY
                and state.is_authenticated
                and not state.is_authenticating
            )
            allow_ytmusic = (
                service == MusicService.YTMUSIC
                and state.ytmusic_credentials_ready
                and not state.is_authenticating
            )
            build_button.disabled = (
                not (allow_spotify or allow_ytmusic)
                or state.is_building_playlist
            )
        spinner = ids.get("music_service_spinner")
        if spinner is not None:
            spinner.text = service.value

        toggle_mapping = {
            "reuse_checkbox": "reuse_existing",
            "truncate_checkbox": "truncate",
            "library_checkbox": "library_artists",
            "followed_checkbox": "followed_artists",
        }
        for widget_id, option_name in toggle_mapping.items():
            widget = ids.get(widget_id)
            if widget is None:
                continue
            if service == MusicService.YTMUSIC:
                if getattr(options, option_name):
                    setattr(options, option_name, False)
                if widget.active:
                    widget.active = False
            else:
                widget.active = getattr(options, option_name)
            widget.disabled = service == MusicService.YTMUSIC

    def _apply_playlist_defaults(self) -> None:
        options = self._state.playlist_options
        ids = self.ids
        mapping = {
            "playlist_name_input": options.playlist_name,
            "playlist_description_input": options.playlist_description or "",
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
        spinner = ids.get("music_service_spinner")
        if spinner is not None:
            spinner.text = options.music_service.value
        self._set_spinner_palette(options.music_service)
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
            disable_for_yt = options.music_service == MusicService.YTMUSIC
            for widget_id in (
                "reuse_checkbox",
                "truncate_checkbox",
                "library_checkbox",
                "followed_checkbox",
            ):
                widget = ids.get(widget_id)
                if widget is not None:
                    widget.disabled = disable_for_yt
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
