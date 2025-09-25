#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SPEC="$ROOT/packaging/AutoPlaylistBuilder.spec"

PYTHON_BIN="python3"
PYINSTALLER_ARGS=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --python)
      if [[ $# -lt 2 ]]; then
        echo "--python requires an interpreter path" >&2
        exit 1
      fi
      PYTHON_BIN="$2"
      shift 2
      ;;
    --clean)
      PYINSTALLER_ARGS+=("--clean")
      shift
      ;;
    *)
      PYINSTALLER_ARGS+=("$1")
      shift
      ;;
  esac
done

if [[ ! -f "$SPEC" ]]; then
  echo "Spec file not found at $SPEC" >&2
  exit 1
fi

export KIVY_NO_ARGS=1

"$PYTHON_BIN" -m PyInstaller "${PYINSTALLER_ARGS[@]}" "$SPEC"

printf "\nPyInstaller build complete. Inspect dist/AutoPlaylistBuilder for the macOS bundle.\n"