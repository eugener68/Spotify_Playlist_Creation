"""Playlist automation orchestrator."""

from __future__ import annotations

import datetime as _dt
import difflib as _dif
import random
import unicodedata as _ud
from dataclasses import dataclass
from pathlib import Path
from typing import Iterable, List, Optional, Sequence, Tuple

from core.playlist_options import PlaylistOptions
from services.spotify_client import (
    Artist,
    PlaylistSummary,
    SpotifyClientError,
    Track,
)


class PlaylistBuilderError(RuntimeError):
    """Raised when playlist creation cannot proceed."""


@dataclass
class PlaylistStats:
    """Structured summary metrics for a playlist build."""

    playlist_name: str
    artists_retrieved: int
    top_tracks_retrieved: int
    variants_deduped: int
    total_prepared: int
    total_uploaded: int

    def lines(self) -> List[str]:
        return [
            f"Playlist name: {self.playlist_name}",
            f"Artists retrieved: {self.artists_retrieved}",
            f"Top songs retrieved: {self.top_tracks_retrieved}",
            f"Variants deduped: {self.variants_deduped}",
            f"Total tracks added to the list: {self.total_uploaded}",
        ]


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
    stats: PlaylistStats


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

        tracks, skipped_duplicates, tracks_retrieved = self._collect_tracks(
            artists,
            options,
        )
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

        existing_playlist: Optional[PlaylistSummary] = None
        if options.reuse_existing:
            if options.target_playlist_id:
                existing_playlist = PlaylistSummary(
                    id=options.target_playlist_id,
                    name=playlist_name,
                    owner_id=user_id,
                    track_count=0,
                )
            if existing_playlist is None:
                existing_playlist = self._client.find_playlist_by_name(
                    playlist_name,
                    owner_id=user_id,
                )

        stats = PlaylistStats(
            playlist_name=playlist_name,
            artists_retrieved=len(artists),
            top_tracks_retrieved=tracks_retrieved,
            variants_deduped=len(skipped_duplicates),
            total_prepared=len(prepared_uris),
            total_uploaded=0,
        )

        if options.dry_run:
            self._log_stats(stats)
            return PlaylistResult(
                playlist_id=existing_playlist.id if existing_playlist else "",
                playlist_name=playlist_name,
                prepared_track_uris=prepared_uris,
                added_track_uris=[],
                display_tracks=display_tracks,
                dry_run=True,
                reused_existing=bool(existing_playlist),
                stats=stats,
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
            existing_uris = self._client.get_playlist_track_uris(
                playlist_id
            )
            existing_uri_set = set(existing_uris)
            if options.truncate:
                self._client.replace_playlist_tracks(
                    playlist_id,
                    prepared_uris,
                )
                added_uris = prepared_uris.copy()
            else:
                added_uris = [
                    uri for uri in prepared_uris if uri not in existing_uri_set
                ]
                if options.shuffle:
                    prepared_uri_set = set(prepared_uris)
                    combined_uris = list(prepared_uris)
                    combined_uris.extend(
                        uri
                        for uri in existing_uris
                        if uri not in prepared_uri_set
                    )
                    if combined_uris:
                        rng = random.Random(options.shuffle_seed)
                        rng.shuffle(combined_uris)
                        self._client.replace_playlist_tracks(
                            playlist_id,
                            combined_uris,
                        )
                elif added_uris:
                    self._client.add_tracks_to_playlist(
                        playlist_id,
                        added_uris,
                    )

        stats.total_uploaded = len(added_uris)
        self._log_stats(stats)

        return PlaylistResult(
            playlist_id=playlist_id or "",
            playlist_name=playlist_name,
            prepared_track_uris=prepared_uris,
            added_track_uris=added_uris,
            display_tracks=display_tracks,
            dry_run=False,
            reused_existing=bool(existing_playlist),
            stats=stats,
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

        manual_artists = self._load_artists_from_manual(options)
        candidates.extend(manual_artists)

        file_artists = self._load_artists_from_file(options)
        candidates.extend(file_artists)

        if options.library_artists or not candidates:
            library_artists = self._client.top_artists(
                limit=max(options.max_artists, 20)
            )
            candidates.extend(library_artists)

        if options.followed_artists or not candidates:
            followed_artists = self._client.followed_artists(
                limit=max(options.max_artists, 20)
            )
            candidates.extend(followed_artists)

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

    def _load_artists_from_manual(
        self,
        options: PlaylistOptions,
    ) -> List[Artist]:
        if not options.manual_artist_queries:
            return []
        resolved: List[Artist] = []
        for query in options.manual_artist_queries:
            normalized = query.strip()
            if not normalized:
                continue
            artist = self._resolve_artist_query(normalized)
            if artist is not None:
                resolved.append(artist)
            elif options.verbose:
                print(f"No Spotify artist found for '{normalized}'")
        return resolved

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
        matches = self._client.search_artists(normalized, limit=10)
        if not matches:
            return None
        target_casefold = normalized.casefold()
        for match in matches:
            if match.name.casefold() == target_casefold:
                return match
        target_simple = _strip_accents(target_casefold)
        for match in matches:
            if _strip_accents(match.name.casefold()) == target_simple:
                return match
        best = _dif.get_close_matches(
            normalized,
            [candidate.name for candidate in matches],
            n=1,
            cutoff=0.6,
        )
        if best:
            for match in matches:
                if match.name == best[0]:
                    return match
        return matches[0]

    def _collect_tracks(
        self,
        artists: Sequence[Artist],
        options: PlaylistOptions,
    ) -> Tuple[List[Track], List[Track], int]:
        dedupe_on_name = options.dedupe_variants
        seen_ids = set()
        seen_names = set()
        selected: List[Track] = []
        skipped: List[Track] = []
        total_tracks_retrieved = 0

        per_artist_limit = max(0, options.limit_per_artist)
        if per_artist_limit == 0:
            return selected, skipped, total_tracks_retrieved

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
            total_tracks_retrieved += len(top_tracks)
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

        return selected, skipped, total_tracks_retrieved

    def _build_description(
        self,
        options: PlaylistOptions,
        skipped_duplicates: Sequence[Track],
    ) -> str:
        return "Generated by Spotify Playlist Builder (© 2025 EugeneR)"

    @staticmethod
    def _format_track(track: Track) -> str:
        artists = ", ".join(track.artists)
        return f"{artists} – {track.name}" if artists else track.name

    @staticmethod
    def _to_track_uri(track: Track) -> str:
        return f"spotify:track:{track.id}"

    @staticmethod
    def _log_stats(stats: PlaylistStats) -> None:
        print("Playlist build stats:")
        for line in stats.lines():
            print(f"  {line}")


def _strip_accents(value: str) -> str:
    normalized = _ud.normalize("NFKD", value)
    return "".join(char for char in normalized if not _ud.combining(char))
