"""Entry point for the Spotify playlist automation application."""

from dotenv import load_dotenv

load_dotenv()

from app import SpotifyPlaylistApp  # noqa: E402


def main() -> None:
    """Launch the Kivy application."""
    SpotifyPlaylistApp().run()


if __name__ == "__main__":
    main()
