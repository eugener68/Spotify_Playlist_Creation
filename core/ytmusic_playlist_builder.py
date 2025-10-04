"""YouTube Music playlist builder mirroring the Spotify workflow."""

from __future__ import annotations

import random
from dataclasses import dataclass
from datetime import datetime
from pathlib import Path
from typing import Iterable, List, Sequence, Tuple

from core.playlist_builder import (
    PlaylistBuilderError,
    PlaylistResult,
    PlaylistStats,
)
from core.playlist_options import PlaylistOptions
from services.ytmusic_client import (
    Artist,
    Track,
    YTMusicClient,
    YTMusicClientError,
)


@dataclass
class _ArtistSelection:
    query: str
    artist: Artist | None


class YTMusicPlaylistBuilder:
    """High-level workflow for assembling YouTube Music playlists."""

    def __init__(self, client: YTMusicClient, *, privacy: str):
        self._client = client
        self._privacy = privacy

    def build(self, options: PlaylistOptions) -> PlaylistResult:
        """Create or update a YouTube Music playlist based on options."""

        if options.reuse_existing:
            raise PlaylistBuilderError(
                "Reusing existing playlists is not yet supported for "
                "YouTube Music."
            )
        if options.truncate:
            raise PlaylistBuilderError(
                "Truncating playlists is not yet supported for YouTube "
                "Music."
            )
        if options.library_artists or options.followed_artists:
            raise PlaylistBuilderError(
                "Library or followed artist sources are not yet supported "
                "for YouTube Music."
            )

        playlist_name = self._build_playlist_name(options)
        artist_queries = self._collect_artist_queries(options)
        if not artist_queries:
            raise PlaylistBuilderError(
                "Provide artist names manually or via an artists file "
                "before building."
            )
        selections = self._resolve_artists(artist_queries, options)
        artists = [
            selection.artist
            for selection in selections
            if selection.artist
        ]
        if not artists:
            raise PlaylistBuilderError(
                "No YouTube Music artists could be resolved from the "
                "supplied queries."
            )

        tracks, skipped_duplicates, total_retrieved = self._collect_tracks(
            artists,
            options,
        )
        if not tracks:
            raise PlaylistBuilderError(
                "No tracks could be generated for the playlist."
            )

        if options.shuffle:
            rng = random.Random(options.shuffle_seed)
            rng.shuffle(tracks)

        prepared_video_ids = self._trim_tracks(
            (track.video_id for track in tracks),
            options.max_tracks,
        )
        prepared_tracks = tracks[: len(prepared_video_ids)]
        display_tracks = [
            self._format_track(track)
            for track in prepared_tracks
        ]

        stats = PlaylistStats(
            playlist_name=playlist_name,
            artists_retrieved=len(artists),
            top_tracks_retrieved=total_retrieved,
            variants_deduped=len(skipped_duplicates),
            total_prepared=len(prepared_video_ids),
            total_uploaded=0,
        )

        if options.dry_run:
            return PlaylistResult(
                playlist_id="",
                playlist_name=playlist_name,
                prepared_track_uris=prepared_video_ids,
                added_track_uris=[],
                display_tracks=display_tracks,
                dry_run=True,
                reused_existing=False,
                stats=stats,
            )

        try:
            playlist_id = self._client.create_playlist(
                playlist_name,
                options.playlist_description
                or self._build_description(options, selections),
                privacy=self._privacy,
            )
            if prepared_video_ids:
                self._client.add_playlist_items(
                    playlist_id,
                    prepared_video_ids,
                )
        except YTMusicClientError as exc:
            raise PlaylistBuilderError(str(exc)) from exc

        stats.total_uploaded = len(prepared_video_ids)

        return PlaylistResult(
            playlist_id=playlist_id,
            playlist_name=playlist_name,
            prepared_track_uris=prepared_video_ids,
            added_track_uris=prepared_video_ids.copy(),
            display_tracks=display_tracks,
            dry_run=False,
            reused_existing=False,
            stats=stats,
        )

    # ------------------------------------------------------------------
    # Helpers

    @staticmethod
    def _build_playlist_name(options: PlaylistOptions) -> str:
        base_name = options.playlist_name.strip() or "Untitled Playlist"
        if not options.date_stamp:
            return base_name
        return f"{base_name} {datetime.now():%Y-%m-%d}"

    def _collect_artist_queries(self, options: PlaylistOptions) -> List[str]:
        queries: List[str] = []
        queries.extend(options.manual_artist_queries)
        file_artists = self._load_artists_from_file(options.artists_file)
        queries.extend(file_artists)
        return [query.strip() for query in queries if query.strip()]

    def _load_artists_from_file(self, artists_file: str | None) -> List[str]:
        if not artists_file:
            return []
        path = Path(artists_file).expanduser()
        if not path.exists():
            raise PlaylistBuilderError(
                f"Artists file '{path}' does not exist."
            )
        try:
            lines = path.read_text(encoding="utf-8").splitlines()
        except OSError as exc:  # pragma: no cover - filesystem dependent
            raise PlaylistBuilderError(
                f"Failed to read artists file '{path}': {exc}"
            ) from exc
        queries: List[str] = []
        for line in lines:
            cleaned = line.strip()
            if not cleaned or cleaned.startswith("#"):
                continue
            queries.append(cleaned)
        return queries

    def _resolve_artists(
        self,
        queries: Sequence[str],
        options: PlaylistOptions,
    ) -> List[_ArtistSelection]:
        selections: List[_ArtistSelection] = []
        for query in queries:
            match: Artist | None = None
            try:
                results = self._client.search_artists(query, limit=1)
            except YTMusicClientError as exc:
                if options.verbose:
                    print(f"Artist lookup failed for '{query}': {exc}")
                results = []
            if results:
                match = results[0]
            elif options.verbose:
                print(f"No YouTube Music artist found for '{query}'")
            selections.append(_ArtistSelection(query=query, artist=match))
        return selections

    def _collect_tracks(
        self,
        artists: Sequence[Artist],
        options: PlaylistOptions,
    ) -> Tuple[List[Track], List[Track], int]:
        limit_per_artist = max(0, options.limit_per_artist)
        if limit_per_artist == 0:
            return [], [], 0
        dedupe_on_name = options.dedupe_variants
        selected: List[Track] = []
        skipped: List[Track] = []
        seen_ids = set()
        seen_titles = set()
        total_retrieved = 0

        for artist in artists:
            try:
                top_tracks = self._client.artist_top_tracks(
                    artist.id,
                    limit=limit_per_artist,
                )
            except YTMusicClientError as exc:
                if options.verbose:
                    print(f"Failed to fetch tracks for '{artist.name}': {exc}")
                continue
            total_retrieved += len(top_tracks)
            for track in top_tracks:
                if not track.video_id:
                    continue
                if track.video_id in seen_ids:
                    skipped.append(track)
                    continue
                normalized_title = track.title.lower()
                if dedupe_on_name and normalized_title in seen_titles:
                    skipped.append(track)
                    continue
                seen_ids.add(track.video_id)
                if dedupe_on_name:
                    seen_titles.add(normalized_title)
                selected.append(track)
                if 0 < options.max_tracks <= len(selected):
                    break
            if 0 < options.max_tracks <= len(selected):
                break

        return selected, skipped, total_retrieved

    @staticmethod
    def _trim_tracks(track_ids: Iterable[str], max_tracks: int) -> List[str]:
        if max_tracks <= 0:
            return list(track_ids)
        trimmed: List[str] = []
        for track_id in track_ids:
            trimmed.append(track_id)
            if len(trimmed) >= max_tracks:
                break
        return trimmed

    @staticmethod
    def _format_track(track: Track) -> str:
        artist_names = ", ".join(track.artists) if track.artists else "Unknown"
        return f"{artist_names} – {track.title}"

    def _build_description(
        self,
        options: PlaylistOptions,
        selections: Sequence[_ArtistSelection],
    ) -> str:
        resolved = [sel.query for sel in selections if sel.artist]
        if not resolved:
            resolved = ["Auto-generated playlist"]
        summary = ", ".join(resolved[:10])
        stamp = datetime.utcnow().strftime("%Y-%m-%d")
        parts = [
            f"Generated on {stamp}",
            f"Artists: {summary}",
        ]
        if options.verbose:
            parts.append("Created with verbose mode enabled")
        return " | ".join(parts)
