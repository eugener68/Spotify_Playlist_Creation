"""Spotify Web API wrapper used by the playlist builder."""

from __future__ import annotations

from dataclasses import dataclass
import re
from typing import Iterable, List, Optional, Sequence

import httpx


class SpotifyClientError(RuntimeError):
    """Raised when Spotify API calls fail."""


@dataclass
class Artist:
    """Minimal artist representation."""

    id: str
    name: str


@dataclass
class Track:
    """Minimal track representation."""

    id: str
    name: str
    artists: List[str]


@dataclass
class PlaylistSummary:
    """Lightweight summary of an existing playlist."""

    id: str
    name: str
    owner_id: str
    track_count: int


class SpotifyClient:
    """Simple HTTPX-based Spotify Web API client."""

    API_BASE = "https://api.spotify.com/v1"

    def __init__(self, access_token: str):
        self._access_token = access_token
        self._client = httpx.Client(
            headers={"Authorization": f"Bearer {access_token}"},
            timeout=20,
        )

    def close(self) -> None:
        """Close the underlying HTTP client."""
        self._client.close()

    def _request(
        self,
        method: str,
        path: str,
        *,
        params: Optional[dict] = None,
        json: Optional[dict] = None,
    ) -> dict:
        response = self._client.request(
            method,
            f"{self.API_BASE}{path}",
            params=params,
            json=json,
        )
        if response.status_code >= 400:
            message = (
                f"{method} {path} failed: {response.status_code}"
                f" {response.text}"
            )
            raise SpotifyClientError(message)
        if response.status_code == 204 or not response.content:
            return {}
        return response.json()

    def _get(self, path: str, params: Optional[dict] = None) -> dict:
        return self._request("GET", path, params=params)

    def current_user(self) -> dict:
        """Return the current user's profile."""
        return self._get("/me")

    def followed_artists(self, limit: int = 50) -> List[Artist]:
        """Fetch the user's followed artists."""
        desired = max(0, limit)
        if desired == 0:
            return []

        collected: List[Artist] = []
        after: Optional[str] = None

        while len(collected) < desired:
            page_limit = min(50, max(1, desired - len(collected)))
            params = {"type": "artist", "limit": page_limit}
            if after:
                params["after"] = after

            data = self._get("/me/following", params=params)
            artists_block = data.get("artists", {})
            items = artists_block.get("items", [])
            for item in items:
                collected.append(Artist(id=item["id"], name=item["name"]))
                if len(collected) >= desired:
                    break

            after = artists_block.get("cursors", {}).get("after")
            if not after or not artists_block.get("next"):
                break

        return collected

    def artist(self, artist_id: str) -> Artist:
        """Fetch a single artist by Spotify ID."""
        data = self._get(f"/artists/{artist_id}")
        return Artist(id=data["id"], name=data.get("name", ""))

    def search_artists(self, query: str, limit: int = 5) -> List[Artist]:
        """Search for artists by name."""
        params = {"q": query, "type": "artist", "limit": limit}
        data = self._get("/search", params=params)
        items = data.get("artists", {}).get("items", [])
        return [
            Artist(id=item.get("id", ""), name=item.get("name", ""))
            for item in items
            if item.get("id")
        ]

    def top_artists(
        self,
        limit: int = 20,
        time_range: str = "medium_term",
    ) -> List[Artist]:
        """Fetch the user's top artists."""
        desired = max(0, limit)
        if desired == 0:
            return []

        collected: List[Artist] = []
        offset = 0

        while len(collected) < desired:
            page_limit = min(50, max(1, desired - len(collected)))
            params = {
                "limit": page_limit,
                "offset": offset,
                "time_range": time_range,
            }
            data = self._get("/me/top/artists", params=params)
            items = data.get("items", [])
            if not items:
                break

            for item in items:
                collected.append(Artist(id=item["id"], name=item["name"]))
                if len(collected) >= desired:
                    break

            offset += len(items)
            if len(items) < page_limit:
                break

        return collected

    def top_tracks_for_artist(
        self,
        artist_id: str,
        limit: int = 10,
    ) -> List[Track]:
        """Fetch an artist's most popular tracks with graceful fallbacks."""
        desired = max(0, limit)
        params = {"market": "from_token"}
        data = self._get(f"/artists/{artist_id}/top-tracks", params=params)
        tracks: List[Track] = []
        seen_ids = set()

        for item in data.get("tracks", []):
            track = self._track_from_payload(item)
            if track.id and track.id not in seen_ids:
                tracks.append(track)
                seen_ids.add(track.id)
            if 0 < desired <= len(tracks):
                return tracks[:desired]

        if desired and len(tracks) >= desired:
            return tracks[:desired]

        # Fallback: walk recent albums/singles until we gather enough tracks.
        for album_id in self._artist_album_ids(artist_id):
            album_tracks = self._get(
                f"/albums/{album_id}/tracks",
                params={"market": "from_token", "limit": 50},
            )
            for item in album_tracks.get("items", []):
                track = self._track_from_payload(item)
                if not track.id or track.id in seen_ids:
                    continue
                # Album cuts already expose participating artists.
                tracks.append(track)
                seen_ids.add(track.id)
                if 0 < desired <= len(tracks):
                    return tracks[:desired]
            if desired and len(tracks) >= desired:
                break

        if desired:
            return tracks[:desired]
        return tracks

    def create_playlist(
        self,
        user_id: str,
        name: str,
        description: str,
        public: bool = False,
    ) -> str:
        """Create a new playlist and return its ID."""
        payload = {
            "name": name,
            "description": description,
            "public": public,
        }
        data = self._request(
            "POST",
            f"/users/{user_id}/playlists",
            json=payload,
        )
        return data["id"]

    def add_tracks_to_playlist(
        self,
        playlist_id: str,
        track_uris: Iterable[str],
    ) -> None:
        """Add tracks to an existing playlist."""
        uri_list = list(track_uris)
        if not uri_list:
            return
        for index in range(0, len(uri_list), 100):
            chunk = uri_list[index:index + 100]
            payload = {"uris": chunk}
            self._request(
                "POST",
                f"/playlists/{playlist_id}/tracks",
                json=payload,
            )

    def replace_playlist_tracks(
        self,
        playlist_id: str,
        track_uris: Sequence[str],
    ) -> None:
        """Replace the full contents of a playlist with the given tracks."""
        uri_list = list(track_uris)
        first_chunk = uri_list[:100]
        self._request(
            "PUT",
            f"/playlists/{playlist_id}/tracks",
            json={"uris": first_chunk},
        )
        remaining = uri_list[100:]
        if remaining:
            self.add_tracks_to_playlist(playlist_id, remaining)

    def get_playlist_track_uris(self, playlist_id: str) -> List[str]:
        """Return the URIs of tracks currently in the playlist."""
        uris: List[str] = []
        params = {"limit": 100, "offset": 0}
        while True:
            data = self._get(f"/playlists/{playlist_id}/tracks", params=params)
            items = data.get("items", [])
            for item in items:
                track = item.get("track")
                if not track:
                    continue
                uri = track.get("uri")
                if uri:
                    uris.append(uri)
            if not data.get("next"):
                break
            params["offset"] = params.get("offset", 0) + params["limit"]
        return uris

    def user_playlists(
        self,
        limit: Optional[int] = 100,
    ) -> List[PlaylistSummary]:
        """Return playlists associated with the current user."""
        playlists: List[PlaylistSummary] = []
        page_limit = 100 if limit is None else min(limit, 100)
        params = {"limit": page_limit, "offset": 0}
        while True:
            data = self._get("/me/playlists", params=params)
            items = data.get("items", [])
            for item in items:
                owner = item.get("owner", {})
                tracks_info = item.get("tracks", {})
                playlists.append(
                    PlaylistSummary(
                        id=item.get("id", ""),
                        name=item.get("name", ""),
                        owner_id=owner.get("id", ""),
                        track_count=tracks_info.get("total", 0),
                    )
                )
                if limit is not None and len(playlists) >= limit:
                    return playlists
            if not data.get("next"):
                break
            params["offset"] = params.get("offset", 0) + params["limit"]
        return playlists

    def _artist_album_ids(self, artist_id: str) -> List[str]:
        """Return album IDs for the given artist ordered by release."""
        params = {
            "include_groups": "album,single,compilation",
            "market": "from_token",
            "limit": 50,
            "offset": 0,
        }
        album_ids: List[str] = []

        while True:
            data = self._get(f"/artists/{artist_id}/albums", params=params)
            items = data.get("items", [])
            for item in items:
                album_id = item.get("id")
                if album_id and album_id not in album_ids:
                    album_ids.append(album_id)
            if not data.get("next"):
                break
            params["offset"] = params.get("offset", 0) + params["limit"]
        return album_ids

    @staticmethod
    def _track_from_payload(payload: dict) -> Track:
        name = payload.get("name", "")
        track_id = payload.get("id", "")
        artists = [
            artist.get("name", "")
            for artist in payload.get("artists", [])
            if artist.get("name")
        ]
        return Track(id=track_id, name=name, artists=artists)

    def find_playlist_by_name(
        self,
        name: str,
        owner_id: Optional[str] = None,
        *,
        search_limit: Optional[int] = None,
    ) -> Optional[PlaylistSummary]:
        """Locate a playlist by matching name (case-insensitive)."""
        needle = name.strip().lower()
        date_suffix_pattern = re.compile(r"\d{4}-\d{2}-\d{2}$")
        fallback: Optional[PlaylistSummary] = None
        for playlist in self.user_playlists(limit=search_limit):
            candidate = playlist.name.strip().lower()
            if owner_id and playlist.owner_id != owner_id:
                continue
            if candidate == needle:
                return playlist
            if candidate.startswith(f"{needle} "):
                suffix = candidate[len(needle):].strip()
                if date_suffix_pattern.match(suffix):
                    fallback = fallback or playlist
        return fallback
