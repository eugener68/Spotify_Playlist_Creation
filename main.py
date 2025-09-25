"""Entry point for the Spotify playlist Builder application."""

import logging
import os
from dotenv import load_dotenv

load_dotenv()

# Configure logging levels before importing any libraries
def configure_logging():
    """Configure logging levels for the application and dependencies."""
    # Get log level from environment (default: WARNING for quiet operation)
    log_level = os.getenv("LOG_LEVEL", "WARNING").upper()
    
    # Configure root logger
    logging.basicConfig(level=getattr(logging, log_level, logging.WARNING))
    
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

from app import AutoPlaylistBuilder  # noqa: E402


def main() -> None:
    """Launch the Kivy application."""
    AutoPlaylistBuilder().run()


if __name__ == "__main__":
    main()
