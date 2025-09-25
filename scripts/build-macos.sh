#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SPEC="$ROOT/packaging/AutoPlaylistBuilder.spec"

if [[ ! -f "$SPEC" ]]; then
  echo "Spec file not found at $SPEC" >&2
  exit 1
fi

export KIVY_NO_ARGS=1

python3 -m PyInstaller "$SPEC" "$@"

echo "\nPyInstaller build completed. Check dist/AutoPlaylistBuilder."