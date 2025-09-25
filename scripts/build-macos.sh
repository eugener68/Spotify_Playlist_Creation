#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SPEC="$ROOT/packaging/AutoPlaylistBuilder-mac.spec"

PYTHON_BIN="python3"
PYINSTALLER_ARGS=()
BUNDLE_ENV=0

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
    --bundle-env)
      BUNDLE_ENV=1
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

if (( ${#PYINSTALLER_ARGS[@]} )); then
  "$PYTHON_BIN" -m PyInstaller "${PYINSTALLER_ARGS[@]}" "$SPEC"
else
  "$PYTHON_BIN" -m PyInstaller "$SPEC"
fi

if (( BUNDLE_ENV )); then
  APP_RESOURCES=""
  if [[ -d "$ROOT/dist/AutoPlaylistBuilder.app/Contents/Resources" ]]; then
    APP_RESOURCES="$ROOT/dist/AutoPlaylistBuilder.app/Contents/Resources"
  elif [[ -d "$ROOT/dist/AutoPlaylistBuilder/AutoPlaylistBuilder.app/Contents/Resources" ]]; then
    APP_RESOURCES="$ROOT/dist/AutoPlaylistBuilder/AutoPlaylistBuilder.app/Contents/Resources"
  fi
  ENV_FILE="$ROOT/.env"

  if [[ -f "$ENV_FILE" && -n "$APP_RESOURCES" ]]; then
    mkdir -p "$APP_RESOURCES"
    cp "$ENV_FILE" "$APP_RESOURCES/.env"
  fi
fi

printf "\nPyInstaller build complete. Inspect dist/AutoPlaylistBuilder for the macOS bundle.\n"