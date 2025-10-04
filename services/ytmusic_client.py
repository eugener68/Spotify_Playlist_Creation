"""YouTube Music API wrapper used by playlist automation tools."""

from __future__ import annotations

from dataclasses import dataclass
from pathlib import Path
import json
import re
from typing import Dict, List, Sequence

from ytmusicapi import YTMusic, setup_oauth
from ytmusicapi.constants import YTM_PARAMS, YTM_PARAMS_KEY
from ytmusicapi.auth.oauth.credentials import OAuthCredentials
from ytmusicapi.exceptions import YTMusicServerError

from config.settings import settings


class YTMusicClientError(RuntimeError):
    """Raised when YouTube Music API calls fail."""


@dataclass
class Artist:
    """Minimal artist representation returned from YouTube Music."""

    id: str
    name: str


@dataclass
class Track:
    """Minimal track representation returned from YouTube Music."""

    video_id: str
    title: str
    artists: List[str]


class YTMusicClient:
    """Convenience wrapper around `ytmusicapi.YTMusic`."""

    _OAUTH_REGRESSION_MSG = (
        "YouTube Music rejected the request with HTTP 400 "
        "(\"Request contains an invalid argument\").\n"
        "Google rolled out a backend change that currently blocks "
        "OAuth-based clients. Track progress at "
        "https://github.com/sigma67/ytmusicapi/issues/813."
    )

    def __init__(self, oauth_path: str):
        target = Path(oauth_path).expanduser()
        if not target.exists():
            raise YTMusicClientError(
                "YouTube Music OAuth credentials not found. "
                "Run YTMusicClient.bootstrap_oauth() first."
            )
        self._oauth_path = target
        client_id = settings.ytmusic_client_id
        client_secret = settings.ytmusic_client_secret
        if not client_id or not client_secret:
            raise YTMusicClientError(
                "YouTube Music OAuth client credentials not configured. "
                "Set GOOGLE_CLIENT_ID and GOOGLE_CLIENT_SECRET (or "
                "YTMUSIC_CLIENT_ID/YTMUSIC_CLIENT_SECRET) in your environment."
            )
        oauth_credentials = OAuthCredentials(
            client_id=client_id,
            client_secret=client_secret,
        )
        self._client = YTMusic(
            str(target),
            oauth_credentials=oauth_credentials,
        )
        self._client.params = YTM_PARAMS + YTM_PARAMS_KEY
        self._oauth_credentials = oauth_credentials
        self._hydrate_context()

    @staticmethod
    def bootstrap_oauth(
        oauth_path: str,
        *,
        client_id: str,
        client_secret: str,
        open_browser: bool = True,
    ) -> Path:
        """Run the interactive OAuth bootstrap flow."""

        target = Path(oauth_path).expanduser()
        target.parent.mkdir(parents=True, exist_ok=True)
        setup_oauth(
            client_id=client_id,
            client_secret=client_secret,
            filepath=str(target),
            open_browser=open_browser,
        )
        return target

    def close(self) -> None:
        """Close the underlying client."""
        # ytmusicapi does not currently expose a close method.
        return

    # ------------------------------------------------------------------
    # Internal helpers

    def _hydrate_context(self) -> None:
        """Populate client context with live Web Remix metadata."""

        try:
            context_snapshot = self._fetch_web_context()
        except Exception:  # pragma: no cover - network dependent
            return

        if not context_snapshot:
            return

        root = self._client.context.setdefault("context", {})
        client_name_numeric = None
        if "INNERTUBE_CONTEXT_CLIENT_NAME" in context_snapshot:
            client_name_numeric = context_snapshot[
                "INNERTUBE_CONTEXT_CLIENT_NAME"
            ]
        for key, value in context_snapshot.items():
            if key == "client":
                client_block: Dict[str, object] = root.setdefault(
                    "client",
                    {},
                )  # type: ignore[assignment]
                client_block.update(value)  # type: ignore[arg-type]
                visitor_id = value.get("visitorData")
                if isinstance(visitor_id, str) and visitor_id:
                    try:
                        base_headers = self._client.base_headers
                        base_headers["X-Goog-Visitor-Id"] = visitor_id
                    except Exception:  # pragma: no cover - defensive
                        pass
                user_agent = value.get("userAgent")
                accept_header = value.get("acceptHeader")
                if isinstance(user_agent, str) and user_agent:
                    base_headers = self._client.base_headers
                    headers = self._client.headers
                    base_headers["user-agent"] = user_agent
                    headers["user-agent"] = user_agent
                if isinstance(accept_header, str) and accept_header:
                    base_headers = self._client.base_headers
                    headers = self._client.headers
                    base_headers["accept"] = accept_header
                    headers["accept"] = accept_header
                for key in ("content-encoding", "content-length"):
                    base_headers.pop(key, None)
                    headers.pop(key, None)
                base_headers = self._client.base_headers
                headers = self._client.headers
                base_headers.setdefault(
                    "referer",
                    "https://music.youtube.com/",
                )
                headers.setdefault(
                    "referer",
                    "https://music.youtube.com/",
                )
                base_headers.setdefault(
                    "accept-language",
                    "en-US,en;q=0.9",
                )
                headers.setdefault(
                    "accept-language",
                    "en-US,en;q=0.9",
                )
            else:
                root[key] = value

        base_headers = self._client.base_headers
        headers = self._client.headers
        client_data = root.get("client", {})
        client_version = client_data.get("clientVersion")
        if client_name_numeric:
            base_headers["x-youtube-client-name"] = str(client_name_numeric)
            headers["x-youtube-client-name"] = str(client_name_numeric)
        if isinstance(client_version, str):
            base_headers["x-youtube-client-version"] = client_version
            headers["x-youtube-client-version"] = client_version
        page_cl = context_snapshot.get("PAGE_CL")
        page_label = context_snapshot.get("PAGE_BUILD_LABEL")
        if page_cl is not None:
            base_headers["x-youtube-page-cl"] = str(page_cl)
            headers["x-youtube-page-cl"] = str(page_cl)
        if isinstance(page_label, str):
            base_headers["x-youtube-page-label"] = page_label
            headers["x-youtube-page-label"] = page_label
        base_headers.setdefault("x-goog-authuser", "0")
        headers.setdefault("x-goog-authuser", "0")

    @staticmethod
    def _translate_error(error: Exception) -> str:
        if isinstance(error, YTMusicServerError):
            message = str(error)
            markers = (
                "Request contains an invalid argument",
                "FAILED_PRECONDITION",
            )
            if any(marker in message for marker in markers):
                return YTMusicClient._OAUTH_REGRESSION_MSG
        return str(error)

    def _fetch_web_context(self) -> Dict[str, object]:
        """Fetch INNERTUBE_CONTEXT data from music.youtube.com."""

        session = self._client._session  # pylint: disable=protected-access
        headers = {
            "User-Agent": (
                "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) "
                "AppleWebKit/537.36 (KHTML, like Gecko) "
                "Chrome/127.0.0.0 Safari/537.36"
            ),
            "Accept": (
                "text/html,application/xhtml+xml,application/xml;"
                "q=0.9,*/*;q=0.8"
            ),
        }
        response = session.get(
            "https://music.youtube.com",
            headers=headers,
            timeout=10,
        )
        response.raise_for_status()

        text = response.text
        marker = '"INNERTUBE_CONTEXT":'
        start = text.find(marker)
        if start == -1:
            return {}
        start += len(marker)
        brace_count = 0
        end = start
        for index, char in enumerate(text[start:], start=start):
            if char == "{":
                brace_count += 1
            elif char == "}":
                brace_count -= 1
                if brace_count == 0:
                    end = index + 1
                    break
        if brace_count != 0:
            return {}

        payload = text[start:end]
        payload = re.sub(r"\\u003d", "=", payload)
        payload = re.sub(r"\\u0026", "&", payload)

        context = json.loads(payload)

        name_match = re.search(
            r"\"INNERTUBE_CONTEXT_CLIENT_NAME\":(\d+)",
            text,
        )
        if name_match:
            context["INNERTUBE_CONTEXT_CLIENT_NAME"] = int(name_match.group(1))

        version_match = re.search(
            r"\"INNERTUBE_CONTEXT_CLIENT_VERSION\":\"([0-9.]+)\"",
            text,
        )
        if version_match:
            context.setdefault("client", {})
            context["client"]["clientVersion"] = version_match.group(1)

        page_cl_match = re.search(r"\"PAGE_CL\":(\d+)", text)
        if page_cl_match:
            context["PAGE_CL"] = int(page_cl_match.group(1))
        page_label_match = re.search(
            r"\"PAGE_BUILD_LABEL\":\"([^\"]+)\"",
            text,
        )
        if page_label_match:
            context["PAGE_BUILD_LABEL"] = page_label_match.group(1)

        return context

    # ------------------------------------------------------------------
    # Lookup helpers

    def search_artists(self, query: str, limit: int = 5) -> List[Artist]:
        """Search for artists by name."""

        if not query.strip():
            return []
        try:
            results = self._client.search(query, filter="artists")
        except Exception as exc:  # pragma: no cover - thin wrapper
            raise YTMusicClientError(self._translate_error(exc)) from exc
        artists: List[Artist] = []
        for item in results or []:
            browse_id = item.get("browseId")
            name = item.get("artist") or item.get("title")
            if not browse_id or not name:
                continue
            artists.append(Artist(id=browse_id, name=name))
            if 0 < limit <= len(artists):
                break
        return artists

    def artist_top_tracks(
        self,
        artist_id: str,
        *,
        limit: int = 10,
    ) -> List[Track]:
        """Return an artist's top tracks."""

        if not artist_id:
            return []
        try:
            data = self._client.get_artist(artist_id)
        except Exception as exc:  # pragma: no cover - thin wrapper
            raise YTMusicClientError(self._translate_error(exc)) from exc
        songs_block = data.get("songs", {}) if isinstance(data, dict) else {}
        if isinstance(songs_block, dict):
            results = songs_block.get("results", [])
        else:
            results = []
        tracks: List[Track] = []
        seen = set()
        for item in results:
            if not isinstance(item, dict):
                continue
            video_id = item.get("videoId")
            title = item.get("title")
            if not video_id or not title or video_id in seen:
                continue
            seen.add(video_id)
            artist_names = [
                artist.get("name", "")
                for artist in item.get("artists", [])
                if isinstance(artist, dict) and artist.get("name")
            ]
            if not artist_names and data.get("name"):
                artist_names = [data["name"]]
            tracks.append(
                Track(
                    video_id=video_id,
                    title=title,
                    artists=artist_names,
                )
            )
            if 0 < limit <= len(tracks):
                break
        return tracks

    # ------------------------------------------------------------------
    # Playlist helpers

    def create_playlist(
        self,
        name: str,
        description: str,
        *,
        privacy: str = "PRIVATE",
    ) -> str:
        """Create a new YouTube Music playlist and return its ID."""

        try:
            return self._client.create_playlist(
                name,
                description,
                privacy=privacy,
            )
        except Exception as exc:  # pragma: no cover - thin wrapper
            raise YTMusicClientError(self._translate_error(exc)) from exc

    def add_playlist_items(
        self,
        playlist_id: str,
        video_ids: Sequence[str],
    ) -> None:
        """Append tracks to an existing playlist."""

        batch: List[str] = []
        for video_id in video_ids:
            if not video_id:
                continue
            batch.append(video_id)
            if len(batch) >= 50:
                self._submit_playlist_batch(playlist_id, batch)
                batch = []
        if batch:
            self._submit_playlist_batch(playlist_id, batch)

    def _submit_playlist_batch(
        self,
        playlist_id: str,
        batch: Sequence[str],
    ) -> None:
        try:
            self._client.add_playlist_items(playlist_id, list(batch))
        except Exception as exc:  # pragma: no cover - thin wrapper
            raise YTMusicClientError(self._translate_error(exc)) from exc

    @staticmethod
    def playlist_url(playlist_id: str) -> str:
        """Return a web URL for the given playlist."""
        return f"https://music.youtube.com/playlist?list={playlist_id}"
