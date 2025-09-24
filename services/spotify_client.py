"""Spotify Web API wrapper used by the playlist builder."""

from __future__ import annotations

from dataclasses import dataclass
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
        params = {"type": "artist", "limit": limit}
        data = self._get("/me/following", params=params)
        artists = data.get("artists", {}).get("items", [])
        return [
            Artist(id=item["id"], name=item["name"])
            for item in artists
        ]

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
        params = {"limit": limit, "time_range": time_range}
        data = self._get("/me/top/artists", params=params)
        return [
            Artist(id=item["id"], name=item["name"])
            for item in data.get("items", [])
        ]

    def top_tracks_for_artist(
        self,
        artist_id: str,
        limit: int = 10,
    ) -> List[Track]:
        """Fetch an artist's top tracks."""
        params = {"market": "from_token"}
        data = self._get(f"/artists/{artist_id}/top-tracks", params=params)
        tracks = []
        for item in data.get("tracks", [])[:limit]:
            name = item.get("name", "")
            track_id = item.get("id", "")
            artists = [
                artist.get("name", "")
                for artist in item.get("artists", [])
            ]
            tracks.append(Track(id=track_id, name=name, artists=artists))
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

    def user_playlists(self, limit: int = 50) -> List[PlaylistSummary]:
        """Return playlists associated with the current user."""
        playlists: List[PlaylistSummary] = []
        params = {"limit": min(limit, 50), "offset": 0}
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
                if len(playlists) >= limit:
                    return playlists
            if not data.get("next"):
                break
            params["offset"] = params.get("offset", 0) + params["limit"]
        return playlists

    def find_playlist_by_name(
        self,
        name: str,
        owner_id: Optional[str] = None,
        *,
        search_limit: int = 200,
    ) -> Optional[PlaylistSummary]:
        """Locate a playlist by exact (case-insensitive) name match."""
        needle = name.strip().lower()
        for playlist in self.user_playlists(limit=search_limit):
            if playlist.name.strip().lower() != needle:
                continue
            if owner_id and playlist.owner_id != owner_id:
                continue
            return playlist
        return None
