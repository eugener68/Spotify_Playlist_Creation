"""Entry point for the Spotify playlist Builder application."""

import io
import logging
import os
import site
import sys
from pathlib import Path

from dotenv import load_dotenv


def ensure_standard_streams() -> None:
    """Ensure stdout/stderr exist even in windowed executables."""
    if sys.stdout is None:
        sys.stdout = open(
            os.devnull,
            "w",
            encoding="utf-8",
            buffering=1,
        )  # type: ignore[assignment]
    if sys.stderr is None:
        sys.stderr = open(
            os.devnull,
            "w",
            encoding="utf-8",
            buffering=1,
        )  # type: ignore[assignment]


ensure_standard_streams()


class _StreamToLogger(io.TextIOBase):
    """File-like wrapper that forwards writes to a logger."""

    def __init__(self, logger: logging.Logger, level: int) -> None:
        super().__init__()
        self._logger = logger
        self._level = level
        self._buffer = ""

    def write(self, message: str) -> int:  # type: ignore[override]
        if not message:
            return 0

        self._buffer += message
        while "\n" in self._buffer:
            line, self._buffer = self._buffer.split("\n", 1)
            if line:
                self._logger.log(self._level, line)
        return len(message)

    def flush(self) -> None:  # type: ignore[override]
        if self._buffer:
            self._logger.log(self._level, self._buffer.rstrip())
            self._buffer = ""


def _redirect_standard_streams_to_logger(enable_console: bool) -> None:
    """Send stdout/stderr output to the log file when console is disabled."""

    if enable_console:
        return

    stdout_logger = logging.getLogger("stdout")
    stderr_logger = logging.getLogger("stderr")

    stdout_logger.setLevel(logging.INFO)
    stderr_logger.setLevel(logging.ERROR)

    sys.stdout = _StreamToLogger(  # type: ignore[assignment]
        stdout_logger,
        logging.INFO,
    )
    sys.stderr = _StreamToLogger(  # type: ignore[assignment]
        stderr_logger,
        logging.ERROR,
    )


def load_environment() -> None:
    """Load environment variables from common locations."""

    candidates: list[Path] = []

    override = os.getenv("ENV_FILE")
    if override:
        candidates.append(Path(override).expanduser())

    module_dir = Path(__file__).resolve().parent
    cwd = Path.cwd()

    candidates.extend(
        [
            module_dir / ".env",
            cwd / ".env",
        ]
    )

    if getattr(sys, "frozen", False):
        exec_dir = Path(sys.executable).resolve().parent
        candidates.extend(
            [
                exec_dir / ".env",
                exec_dir.parent / ".env",
                exec_dir.parent / "Resources" / ".env",
                exec_dir.parent.parent / ".env",
            ]
        )

    loaded = False
    loaded_paths: list[Path] = []
    seen: set[Path] = set()
    for candidate in candidates:
        if candidate in seen:
            continue
        seen.add(candidate)
        if candidate.exists():
            load_dotenv(candidate, override=True)
            loaded = True
            loaded_paths.append(candidate)

    if not loaded:
        load_dotenv()
    # Persist sources for later logging after logging is configured
    if loaded_paths:
        os.environ["ENV_SOURCES"] = ",".join(str(p) for p in loaded_paths)
    else:
        os.environ.pop("ENV_SOURCES", None)


load_environment()

# Configure logging levels before importing any libraries


def _default_log_directory() -> Path:
    """Determine the directory where log files should be written."""
    env_override = os.getenv("LOG_DIR")
    if env_override:
        return Path(env_override).expanduser()

    if getattr(sys, "frozen", False):
        exec_dir = Path(sys.executable).resolve().parent
        # Keep packaged logs alongside the bundled executable
        return exec_dir / "logs"

    return Path.cwd() / "logs"


def configure_logging():
    """Configure logging levels for the application and dependencies."""
    log_level = os.getenv("LOG_LEVEL", "WARNING").upper()

    log_dir = _default_log_directory()
    log_dir.mkdir(parents=True, exist_ok=True)
    log_file = log_dir / "app.log"

    handlers = [logging.FileHandler(log_file, encoding="utf-8")]

    console_pref = os.getenv("ENABLE_CONSOLE_LOGS")
    if console_pref is None:
        enable_console = not getattr(sys, "frozen", False)
    else:
        enable_console = console_pref.strip().lower() in {
            "1",
            "true",
            "yes",
            "on",
        }

    if enable_console:
        os.environ.pop("KIVY_NO_CONSOLELOG", None)
    else:
        os.environ.setdefault("KIVY_NO_CONSOLELOG", "1")

    if enable_console and sys.stderr is not None:
        handlers.append(logging.StreamHandler(sys.stderr))

    logging.basicConfig(
        level=getattr(logging, log_level, logging.WARNING),
        handlers=handlers,
        force=True,
    )

    logging.getLogger("httpx").setLevel(logging.WARNING)
    logging.getLogger("httpcore").setLevel(logging.WARNING)
    logging.getLogger("urllib3").setLevel(logging.WARNING)

    http_info_level = os.getenv("HTTP_LOG_LEVEL", "WARNING").upper()

    logging.getLogger("httpx").setLevel(
        getattr(logging, http_info_level, logging.WARNING)
    )

    _redirect_standard_streams_to_logger(enable_console)

configure_logging()  # noqa: E305

# Log environment sources after logging is configured
env_sources = os.getenv("ENV_SOURCES")
if env_sources:
    logging.getLogger(__name__).info("Loaded environment from: %s", env_sources)
else:
    logging.getLogger(__name__).info("No project .env file found; using process environment only")

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
