"""Playlist automation orchestrator."""

from __future__ import annotations

import datetime as _dt
import difflib as _dif
import heapq
import random
import re
import unicodedata as _ud
from collections import defaultdict
from dataclasses import dataclass
from pathlib import Path
from typing import Dict, Iterable, List, Optional, Sequence, Tuple

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

        if options.shuffle and tracks:
            rng = random.Random(options.shuffle_seed)
            tracks = _shuffle_without_adjacent_artist_runs(tracks, rng)

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
        seen_names: Dict[Tuple[str, ...], List[str]] = defaultdict(list)
        selected: List[Track] = []
        skipped: List[Track] = []
        total_tracks_retrieved = 0

        per_artist_limit = max(0, options.limit_per_artist)
        if per_artist_limit == 0:
            return selected, skipped, total_tracks_retrieved

        for artist in artists:
            fetch_limit = per_artist_limit
            if dedupe_on_name:
                fetch_limit = max(per_artist_limit + 5, per_artist_limit * 2)
            fetch_limit = max(fetch_limit, per_artist_limit)
            try:
                top_tracks = self._client.top_tracks_for_artist(
                    artist.id,
                    limit=fetch_limit,
                )
            except SpotifyClientError:
                if options.verbose:
                    print(
                        f"Failed to fetch tracks for artist '{artist.name}'"
                    )
                continue
            total_tracks_retrieved += len(top_tracks)
            tracks_added_for_artist = 0
            for track in top_tracks:
                if not track.id:
                    continue
                if track.id in seen_ids:
                    skipped.append(track)
                    continue
                fingerprint: Optional[Tuple[str, ...]] = None
                if dedupe_on_name:
                    fingerprint = _artist_fingerprint(track)
                    normalized = _normalize_track_name(track.name)
                    if _is_duplicate_variant(
                        normalized,
                        seen_names[fingerprint],
                    ):
                        skipped.append(track)
                        continue
                seen_ids.add(track.id)
                if dedupe_on_name:
                    fingerprint = fingerprint or _artist_fingerprint(track)
                    normalized = _normalize_track_name(track.name)
                    if normalized:
                        seen_names[fingerprint].append(normalized)
                selected.append(track)
                tracks_added_for_artist += 1
                if 0 < options.max_tracks <= len(selected):
                    break
                if tracks_added_for_artist >= per_artist_limit:
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


def _shuffle_without_adjacent_artist_runs(
    tracks: Sequence[Track],
    rng: random.Random,
) -> List[Track]:
    if len(tracks) <= 1:
        return list(tracks)
    buckets: Dict[str, List[Track]] = defaultdict(list)
    for track in tracks:
        buckets[_primary_artist(track)].append(track)
    for entries in buckets.values():
        rng.shuffle(entries)
    heap: List[Tuple[int, float, str]] = []
    for artist, entries in buckets.items():
        if not entries:
            continue
        heapq.heappush(heap, (-len(entries), rng.random(), artist))
    result: List[Track] = []
    prev_artist: Optional[str] = None
    while heap:
        count, _, artist = heapq.heappop(heap)
        if artist == prev_artist and heap:
            heapq.heappush(heap, (count, rng.random(), artist))
            count, _, artist = heapq.heappop(heap)
        track_list = buckets[artist]
        track = track_list.pop()
        result.append(track)
        prev_artist = artist
        if track_list:
            heapq.heappush(
                heap,
                (-len(track_list), rng.random(), artist),
            )
    return result


def _is_duplicate_variant(
    candidate: str,
    existing: Sequence[str],
) -> bool:
    if not candidate:
        return False
    if candidate in existing:
        return True
    for entry in existing:
        if not entry:
            continue
        similarity = _dif.SequenceMatcher(None, candidate, entry).ratio()
        if similarity >= 0.92:
            return True
        cand_tokens = _token_signature(candidate)
        entry_tokens = _token_signature(entry)
        if cand_tokens and cand_tokens == entry_tokens:
            return True
        if (
            _is_subset_phrase(candidate, entry)
            or _is_subset_phrase(entry, candidate)
        ):
            return True
    return False


def _normalize_track_name(name: str) -> str:
    text = name.casefold()
    text = _strip_accents(text)
    text = text.replace("ё", "е")
    text = re.sub(r"[""“”«»]", "", text)
    text = re.sub(r"[()\[\]{}]", " ", text)
    text = re.sub(
        (
            r"\s*[-–—]\s*("
            r"remaster(?:ed)?|live|bonus|edit|mix|version|single|"
            r"ost|from|из"
            r")\b.*"
        ),
        "",
        text,
    )
    text = re.sub(r"\s+feat\.?\b.*", "", text)
    text = re.sub(r"\s*[-–—~]\s*", " ", text)
    text = re.sub(
        r"\b(acoustic|instrumental|karaoke|mashup|live|orchestral|"
        r"symphonic|bonus|edit|mix|version|explicit)\b",
        "",
        text,
    )
    text = re.sub(r"[^0-9a-zа-яёіїґ]+", " ", text)
    return " ".join(text.split())


def _primary_artist(track: Track) -> str:
    return track.artists[0] if track.artists else ""


def _artist_fingerprint(track: Track) -> Tuple[str, ...]:
    names = [name.casefold() for name in track.artists if name]
    if not names:
        return ("",)
    return tuple(sorted(names))


def _token_signature(text: str) -> Tuple[str, ...]:
    if not text:
        return ()
    tokens = sorted(set(token for token in text.split() if token))
    return tuple(tokens)


def _is_subset_phrase(a: str, b: str) -> bool:
    if not a or not b:
        return False
    if a == b:
        return True
    if a in b and len(a) >= max(4, len(b) * 0.6):
        return True
    return False


def _strip_accents(value: str) -> str:
    normalized = _ud.normalize("NFKD", value)
    return "".join(char for char in normalized if not _ud.combining(char))
