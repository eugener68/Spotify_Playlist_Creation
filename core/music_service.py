"""Enumeration of supported music services."""

from __future__ import annotations

from enum import Enum


class MusicService(str, Enum):
    """Supported music providers."""

    SPOTIFY = "SPOTIFY"
    YTMUSIC = "YTMUSIC"
