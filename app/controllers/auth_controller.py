"""Controller that manages Spotify OAuth flow for the Kivy app."""

from __future__ import annotations

import threading
import time
import webbrowser
from dataclasses import dataclass
from http.server import BaseHTTPRequestHandler, HTTPServer
from typing import Optional
from urllib.parse import parse_qs, urlparse

from kivy.app import App
from kivy.clock import Clock

from app.state.app_state import AppState
from config.settings import settings
from services.spotify_auth import SpotifyAuthError, SpotifyOAuthClient
from services.spotify_client import SpotifyClient, SpotifyClientError


@dataclass
class _AuthResult:
    code: Optional[str] = None
    error: Optional[str] = None
    state: Optional[str] = None


class AuthController:
    """Async helper for coordinating the user sign-in flow."""

    def __init__(self, app: App):
        self._app = app
        self._lock = threading.Lock()
        self._thread: Optional[threading.Thread] = None

    @property
    def state(self) -> AppState:
        return self._app.state  # type: ignore[attr-defined]

    def sign_in(self) -> None:
        """Kick off the OAuth sign-in flow on a worker thread."""
        with self._lock:
            if self.state.is_authenticating:
                return
            self.state.mark_auth_started(
                "Opening browser for Spotify sign-in..."
            )
            thread = threading.Thread(target=self._run_flow, daemon=True)
            self._thread = thread
            thread.start()

    def sign_out(self) -> None:
        """Revoke local tokens and reset the UI state."""
        self.state.clear_tokens()

    # ---------------------------------------------------------------------
    # Internal implementation details

    def _run_flow(self) -> None:
        try:
            self._ensure_client_id_present()
            oauth = SpotifyOAuthClient()
            redirect_uri = (
                f"http://127.0.0.1:{settings.redirect_port}/callback"
            )
            authorize_url, verifier = oauth.build_authorize_url(redirect_uri)
            result = self._await_browser_callback(authorize_url)
            if result.error:
                raise SpotifyAuthError(
                    f"Spotify returned error: {result.error}"
                )
            if not result.code:
                raise SpotifyAuthError("Authorization code not received")
            token = oauth.exchange_code(result.code, verifier, redirect_uri)
            profile = self._fetch_profile(token.access_token)
            display_name = profile.get("display_name") or profile.get("email")
            expires_at = time.time() + token.expires_in
            Clock.schedule_once(
                lambda _dt: self.state.mark_auth_success(
                    access_token=token.access_token,
                    refresh_token=token.refresh_token,
                    expires_at=expires_at,
                    scope=token.scope,
                    display_name=display_name,
                )
            )
        except Exception as error:  # pylint: disable=broad-except
            message = str(error)
            Clock.schedule_once(
                lambda _dt: self.state.mark_auth_failure(message)
            )
        finally:
            Clock.schedule_once(lambda _dt: self.state.mark_auth_finished())

    def _ensure_client_id_present(self) -> None:
        if not settings.client_id:
            raise SpotifyAuthError(
                "SPOTIFY_CLIENT_ID is not configured. Update your .env file."
            )

    def _await_browser_callback(self, authorize_url: str) -> _AuthResult:
        """Open the browser and wait for the Spotify redirect."""
        result = _AuthResult()

        class _Handler(BaseHTTPRequestHandler):  # type: ignore[misc]
            def do_GET(self):  # type: ignore[override]
                parsed = urlparse(self.path)
                if parsed.path != "/callback":
                    self.send_error(404, "Not Found")
                    return
                params = parse_qs(parsed.query)
                result.code = params.get("code", [None])[0]
                result.error = params.get("error", [None])[0]
                result.state = params.get("state", [None])[0]
                self.send_response(200)
                self.send_header("Content-Type", "text/html; charset=utf-8")
                self.end_headers()
                self.wfile.write(
                    b"<html><body><h1>Authorization received.</h1>"
                    b"<p>You may close this window and return to the app.</p>"
                    b"</body></html>"
                )

            def log_message(self, format, *args):  # type: ignore[override]
                # Suppress default stdout logging noise.
                return

        server = HTTPServer(("127.0.0.1", settings.redirect_port), _Handler)
        server.timeout = 1.0
        webbrowser.open(authorize_url)
        timeout_at = time.time() + 300  # 5 minutes
        try:
            while (
                time.time() < timeout_at
                and not result.code
                and not result.error
            ):
                server.handle_request()
            if not result.code and not result.error:
                raise SpotifyAuthError(
                    "Timed out waiting for Spotify authorization"
                )
            return result
        finally:
            server.server_close()

    def _fetch_profile(self, access_token: str) -> dict:
        """Retrieve the current user's profile from Spotify."""
        try:
            client = SpotifyClient(access_token)
            profile = client.current_user()
            client.close()
            return profile
        except SpotifyClientError as exc:  # pragma: no cover - thin wrapper
            raise SpotifyAuthError(str(exc)) from exc
