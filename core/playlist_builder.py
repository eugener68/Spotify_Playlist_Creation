"""Playlist automation orchestrator."""

from __future__ import annotations

import datetime as _dt
import random
from dataclasses import dataclass
from pathlib import Path
from typing import Iterable, List, Optional, Sequence, Tuple

from core.playlist_options import PlaylistOptions
from services.spotify_client import (
    Artist,
    SpotifyClientError,
    Track,
)


class PlaylistBuilderError(RuntimeError):
    """Raised when playlist creation cannot proceed."""


@dataclass
class PlaylistResult:
    """Summarized playlist creation result."""

    playlist_id: str
    playlist_name: str
    prepared_track_uris: List[str]
    added_track_uris: List[str]
    display_tracks: List[str]
    dry_run: bool
    reused_existing: bool


class PlaylistBuilder:
    """High-level workflow for assembling and uploading playlists."""

    def __init__(self, spotify_client):  # type: ignore[no-untyped-def]
        self._client = spotify_client

    def build(self, options: PlaylistOptions) -> PlaylistResult:
        """Create or update a Spotify playlist based on the given options."""
        playlist_name = self._build_playlist_name(options)
        profile = self._client.current_user()
        user_id = profile.get("id")
        if not user_id:
            raise PlaylistBuilderError(
                "Spotify profile did not include a user identifier."
            )

        artists = self._collect_artists(options, user_id)
        if not artists:
            raise PlaylistBuilderError(
                "No artists were resolved from the configured sources."
            )

        tracks, skipped_duplicates = self._collect_tracks(artists, options)
        if not tracks and not options.truncate:
            raise PlaylistBuilderError(
                "No tracks could be generated for the playlist."
            )

        if options.shuffle:
            rng = random.Random(options.shuffle_seed)
            rng.shuffle(tracks)

        prepared_uris = self.trim_tracks(
            (self._to_track_uri(track) for track in tracks),
            options.max_tracks,
        )
        prepared_tracks = tracks[: len(prepared_uris)]
        display_tracks = [
            self._format_track(track)
            for track in prepared_tracks
        ]

        existing_playlist = (
            self._client.find_playlist_by_name(playlist_name, owner_id=user_id)
            if options.reuse_existing
            else None
        )

        if options.dry_run:
            return PlaylistResult(
                playlist_id=existing_playlist.id if existing_playlist else "",
                playlist_name=playlist_name,
                prepared_track_uris=prepared_uris,
                added_track_uris=[],
                display_tracks=display_tracks,
                dry_run=True,
                reused_existing=bool(existing_playlist),
            )

        playlist_id: Optional[str]
        added_uris: List[str] = []

        if existing_playlist is None:
            playlist_id = self._client.create_playlist(
                user_id,
                playlist_name,
                self._build_description(options, skipped_duplicates),
                public=False,
            )
            if prepared_uris:
                self._client.add_tracks_to_playlist(playlist_id, prepared_uris)
                added_uris = prepared_uris.copy()
        else:
            playlist_id = existing_playlist.id
            if options.truncate:
                self._client.replace_playlist_tracks(
                    playlist_id,
                    prepared_uris,
                )
                added_uris = prepared_uris.copy()
            else:
                existing_uris = self._client.get_playlist_track_uris(
                    playlist_id
                )
                missing = [
                    uri for uri in prepared_uris if uri not in existing_uris
                ]
                if missing:
                    self._client.add_tracks_to_playlist(playlist_id, missing)
                    added_uris = missing

        return PlaylistResult(
            playlist_id=playlist_id or "",
            playlist_name=playlist_name,
            prepared_track_uris=prepared_uris,
            added_track_uris=added_uris,
            display_tracks=display_tracks,
            dry_run=False,
            reused_existing=bool(existing_playlist),
        )

    @staticmethod
    def trim_tracks(track_ids: Iterable[str], max_tracks: int) -> List[str]:
        """Trim a sequence of track IDs to the configured limit."""
        if max_tracks <= 0:
            return list(track_ids)
        result: List[str] = []
        for track_id in track_ids:
            result.append(track_id)
            if len(result) >= max_tracks:
                break
        return result

    # ------------------------------------------------------------------
    # Internal helpers

    def _build_playlist_name(self, options: PlaylistOptions) -> str:
        base_name = options.playlist_name.strip() or "Untitled Playlist"
        if not options.date_stamp:
            return base_name
        stamp = _dt.datetime.now().strftime("%Y-%m-%d")
        return f"{base_name} {stamp}"

    def _collect_artists(
        self,
        options: PlaylistOptions,
        user_id: str,
    ) -> List[Artist]:
        candidates: List[Artist] = []

        file_artists = self._load_artists_from_file(options)
        candidates.extend(file_artists)

        if options.library_artists or not candidates:
            library_artists = self._client.top_artists(
                limit=max(options.max_artists, 20)
            )
            candidates.extend(library_artists)

        deduped: List[Artist] = []
        seen_ids = set()
        for artist in candidates:
            if artist.id in seen_ids:
                continue
            if not artist.name:
                continue
            deduped.append(artist)
            seen_ids.add(artist.id)
            if 0 < options.max_artists <= len(deduped):
                break

        return deduped

    def _load_artists_from_file(
        self,
        options: PlaylistOptions,
    ) -> List[Artist]:
        if not options.artists_file:
            return []
        path = Path(options.artists_file).expanduser()
        if not path.exists():
            raise PlaylistBuilderError(
                f"Artists file '{path}' does not exist."
            )
        try:
            queries = [
                line.strip()
                for line in path.read_text(encoding="utf-8").splitlines()
                if line.strip() and not line.strip().startswith("#")
            ]
        except OSError as exc:  # pragma: no cover - filesystem dependent
            raise PlaylistBuilderError(
                f"Failed to read artists file '{path}': {exc}"
            ) from exc

        resolved: List[Artist] = []
        for query in queries:
            artist = self._resolve_artist_query(query)
            if artist is not None:
                resolved.append(artist)
            elif options.verbose:
                print(f"No Spotify artist found for '{query}'")
        return resolved

    def _resolve_artist_query(self, query: str) -> Optional[Artist]:
        normalized = query.strip()
        if not normalized:
            return None
        if normalized.startswith("spotify:artist:"):
            artist_id = normalized.split(":")[-1]
            return self._client.artist(artist_id)
        if "open.spotify.com/artist" in normalized:
            artist_id = normalized.rstrip("/").split("/")[-1].split("?")[0]
            return self._client.artist(artist_id)
        matches = self._client.search_artists(normalized, limit=1)
        return matches[0] if matches else None

    def _collect_tracks(
        self,
        artists: Sequence[Artist],
        options: PlaylistOptions,
    ) -> Tuple[List[Track], List[Track]]:
        dedupe_on_name = options.dedupe_variants
        seen_ids = set()
        seen_names = set()
        selected: List[Track] = []
        skipped: List[Track] = []

        per_artist_limit = max(0, options.limit_per_artist)
        if per_artist_limit == 0:
            return selected, skipped

        for artist in artists:
            try:
                top_tracks = self._client.top_tracks_for_artist(
                    artist.id,
                    limit=per_artist_limit,
                )
            except SpotifyClientError:
                if options.verbose:
                    print(
                        f"Failed to fetch tracks for artist '{artist.name}'"
                    )
                continue
            for track in top_tracks:
                if not track.id:
                    continue
                if track.id in seen_ids:
                    skipped.append(track)
                    continue
                normalized_name = track.name.lower()
                if dedupe_on_name and normalized_name in seen_names:
                    skipped.append(track)
                    continue
                seen_ids.add(track.id)
                if dedupe_on_name:
                    seen_names.add(normalized_name)
                selected.append(track)
                if 0 < options.max_tracks <= len(selected):
                    break
            if 0 < options.max_tracks <= len(selected):
                break

        return selected, skipped

    def _build_description(
        self,
        options: PlaylistOptions,
        skipped_duplicates: Sequence[Track],
    ) -> str:
        parts = ["Generated by Spotify Playlist Automation"]
        if options.artists_file:
            parts.append(
                f"source file: {Path(options.artists_file).expanduser().name}"
            )
        if options.library_artists:
            parts.append("+ library artists")
        if skipped_duplicates:
            parts.append(
                f"deduped {len(skipped_duplicates)} variants"
            )
        return " | ".join(parts)

    @staticmethod
    def _format_track(track: Track) -> str:
        artists = ", ".join(track.artists)
        return f"{artists} – {track.name}" if artists else track.name

    @staticmethod
    def _to_track_uri(track: Track) -> str:
        return f"spotify:track:{track.id}"
