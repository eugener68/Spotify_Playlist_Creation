"""Spotify OAuth flow helpers (Authorization Code with PKCE)."""

from __future__ import annotations

import base64
import hashlib
import secrets
import string
from dataclasses import dataclass
from typing import Optional

import httpx

from config.settings import settings


@dataclass
class TokenResponse:
    """Normalized token response from Spotify."""

    access_token: str
    refresh_token: Optional[str]
    expires_in: int
    scope: str


class SpotifyAuthError(RuntimeError):
    """Raised when the OAuth flow fails."""


class SpotifyOAuthClient:
    """Handle the Authorization Code with PKCE flow for Spotify."""

    AUTHORIZE_URL = "https://accounts.spotify.com/authorize"
    TOKEN_URL = "https://accounts.spotify.com/api/token"

    def __init__(self, client_id: Optional[str] = None):
        self._client_id = client_id or settings.client_id
        if not self._client_id:
            raise SpotifyAuthError("SPOTIFY_CLIENT_ID not configured")

    @staticmethod
    def _generate_code_verifier(length: int = 64) -> str:
        alphabet = string.ascii_letters + string.digits + "-._~"
        return "".join(secrets.choice(alphabet) for _ in range(length))

    @staticmethod
    def _code_challenge_from_verifier(verifier: str) -> str:
        digest = hashlib.sha256(verifier.encode("ascii")).digest()
        return base64.urlsafe_b64encode(digest).rstrip(b"=").decode("ascii")

    @staticmethod
    def _generate_state(length: int = 16) -> str:
        alphabet = string.ascii_letters + string.digits
        return "".join(secrets.choice(alphabet) for _ in range(length))

    def build_authorize_url(
        self,
        redirect_uri: str,
        state: Optional[str] = None,
    ) -> tuple[str, str]:
        """Construct an authorize URL and return it along with the verifier."""
        verifier = self._generate_code_verifier()
        challenge = self._code_challenge_from_verifier(verifier)
        state = state or self._generate_state()
        params = httpx.QueryParams(
            {
                "client_id": self._client_id,
                "response_type": "code",
                "redirect_uri": redirect_uri,
                "scope": " ".join(settings.scopes),
                "code_challenge_method": "S256",
                "code_challenge": challenge,
                "state": state,
                "show_dialog": "false",
            }
        )
        return f"{self.AUTHORIZE_URL}?{params}", verifier

    def exchange_code(
        self,
        code: str,
        verifier: str,
        redirect_uri: str,
    ) -> TokenResponse:
        """Exchange an authorization code for tokens."""
        data = {
            "grant_type": "authorization_code",
            "code": code,
            "redirect_uri": redirect_uri,
            "client_id": self._client_id,
            "code_verifier": verifier,
        }
        response = httpx.post(self.TOKEN_URL, data=data, timeout=20)
        response.raise_for_status()
        payload = response.json()
        return TokenResponse(
            access_token=payload["access_token"],
            refresh_token=payload.get("refresh_token"),
            expires_in=payload["expires_in"],
            scope=payload.get("scope", ""),
        )

    def refresh_token(self, refresh_token: str) -> TokenResponse:
        """Refresh an access token using the refresh token."""
        data = {
            "grant_type": "refresh_token",
            "refresh_token": refresh_token,
            "client_id": self._client_id,
        }
        response = httpx.post(self.TOKEN_URL, data=data, timeout=20)
        response.raise_for_status()
        payload = response.json()
        return TokenResponse(
            access_token=payload["access_token"],
            refresh_token=payload.get("refresh_token", refresh_token),
            expires_in=payload["expires_in"],
            scope=payload.get("scope", ""),
        )
