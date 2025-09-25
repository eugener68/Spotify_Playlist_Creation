"""Entry point for the Spotify playlist Builder application."""

import logging
import os
import site
import sys
from pathlib import Path
from dotenv import load_dotenv

load_dotenv()


def ensure_standard_streams() -> None:
    """Ensure stdout/stderr exist even in windowed executables."""
    if sys.stdout is None:
        sys.stdout = open(os.devnull, "w", encoding="utf-8", buffering=1)  # type: ignore[assignment]
    if sys.stderr is None:
        sys.stderr = open(os.devnull, "w", encoding="utf-8", buffering=1)  # type: ignore[assignment]


ensure_standard_streams()

# Configure logging levels before importing any libraries
def configure_logging():
    """Configure logging levels for the application and dependencies."""
    # Get log level from environment (default: WARNING for quiet operation)
    log_level = os.getenv("LOG_LEVEL", "WARNING").upper()
    
    # Configure root logger
    log_dir = Path(os.getenv("LOG_DIR", Path.cwd() / "logs"))
    log_dir.mkdir(parents=True, exist_ok=True)
    log_file = log_dir / "app.log"

    handlers = [
        logging.StreamHandler(sys.stderr),
        logging.FileHandler(log_file, encoding="utf-8"),
    ]

    logging.basicConfig(
        level=getattr(logging, log_level, logging.WARNING),
        handlers=handlers,
        force=True,
    )
    
    # Specifically suppress DEBUG logs from HTTP libraries
    logging.getLogger("httpx").setLevel(logging.WARNING)
    logging.getLogger("httpcore").setLevel(logging.WARNING)
    logging.getLogger("urllib3").setLevel(logging.WARNING)
    
    # Keep INFO level for HTTP request summaries if desired
    http_info_level = os.getenv("HTTP_LOG_LEVEL", "WARNING").upper()
    logging.getLogger("httpx").setLevel(getattr(logging, http_info_level, logging.WARNING))

configure_logging()

# Configure Kivy logging before importing Kivy
kivy_log_level = os.getenv("KIVY_LOG_LEVEL", "INFO").upper()
os.environ["KIVY_LOG_LEVEL"] = kivy_log_level

# Ensure site.USER_BASE is available for dependencies like kivy_deps.angle
if getattr(site, "USER_BASE", None) is None:
    user_base_fallback = sys.prefix
    site.USER_BASE = user_base_fallback
    os.environ.setdefault("PYTHONUSERBASE", user_base_fallback)

from app import AutoPlaylistBuilder  # noqa: E402


def main() -> None:
    """Launch the Kivy application."""
    AutoPlaylistBuilder().run()


if __name__ == "__main__":
    main()
