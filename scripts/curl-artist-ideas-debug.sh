#!/usr/bin/env bash
set -euo pipefail

# Interactive curl helper for POST /artist-ideas with debug output.
#
# Prereqs:
# - curl
# - python3 (used to JSON-escape the prompt safely)
#
# Configure via env vars (recommended):
#   export SVC_URL="https://<your-cloud-run-url>"
#   export SUGGESTIONS_API_KEY="<your-api-key>"   # omit if your service doesn't require it
#
# Run:
#   ./scripts/curl-artist-ideas-debug.sh
#
# Optional env vars:
#   ARTIST_COUNT=20 DEBUG=true

if ! command -v curl >/dev/null 2>&1; then
  echo "curl not found" >&2
  exit 1
fi
if ! command -v python3 >/dev/null 2>&1; then
  echo "python3 not found (needed to escape JSON safely)" >&2
  exit 1
fi

DEFAULT_SVC_URL="https://spotify-suggestions-951280520300.us-central1.run.app/suggestions"
SVC_URL="${SVC_URL:-$DEFAULT_SVC_URL}"
if [[ -z "$SVC_URL" ]]; then
  read -r -p "Cloud Run base URL (e.g. https://...): " SVC_URL
fi
SVC_URL="${SVC_URL%/}"

# Allow users to paste the existing /suggestions endpoint (as stored in AppSecrets.plist).
# We need the service base URL because this script calls /artist-ideas.
if [[ "$SVC_URL" == */suggestions ]]; then
  SVC_URL="${SVC_URL%/suggestions}"
fi

ARTIST_COUNT="${ARTIST_COUNT:-20}"
DEBUG="${DEBUG:-true}"

normalize_api_key() {
  # Trim whitespace/newlines and remove a trailing '%' which often appears in zsh
  # output when the producer doesn't emit a final newline.
  # (The '%' is not part of the secret value.)
  python3 - <<'PY'
import os
key = os.environ.get('RAW_KEY', '')
key = key.strip().replace('\r', '').replace('\n', '')
if key.endswith('%'):
  key = key[:-1]
print(key)
PY
}

maybe_load_api_key_from_gcloud() {
  if [[ -n "${SUGGESTIONS_API_KEY:-}" ]]; then
    return
  fi
  if ! command -v gcloud >/dev/null 2>&1; then
    return
  fi
  # Optional convenience: fetch from Secret Manager if access is configured.
  # This keeps your terminal history clean (no copy/paste).
  if gcloud secrets describe suggestions-api-key >/dev/null 2>&1; then
    SUGGESTIONS_API_KEY="$(gcloud secrets versions access latest --secret='suggestions-api-key' 2>/dev/null || true)"
  fi
}

maybe_load_api_key_from_gcloud

echo "Enter prompt (finish with Enter):"
read -r PROMPT

if [[ -z "${PROMPT// }" ]]; then
  echo "Prompt is empty; aborting." >&2
  exit 1
fi

JSON_PAYLOAD="$(
  PROMPT="$PROMPT" ARTIST_COUNT="$ARTIST_COUNT" DEBUG="$DEBUG" python3 - <<'PY'
import json, os
prompt = os.environ["PROMPT"]
artist_count = int(os.environ.get("ARTIST_COUNT", "20"))
debug = os.environ.get("DEBUG", "true").lower() in ("1","true","yes","y")
print(json.dumps({"prompt": prompt, "artistCount": artist_count, "debug": debug}))
PY
)"

echo
echo "POST ${SVC_URL}/artist-ideas"

# Pretty-print if jq is available.
if command -v jq >/dev/null 2>&1; then
  if [[ -n "${SUGGESTIONS_API_KEY:-}" ]]; then
    API_KEY="$(RAW_KEY="$SUGGESTIONS_API_KEY" normalize_api_key)"
    curl -sS -X POST "${SVC_URL}/artist-ideas" \
      -H "Content-Type: application/json" \
      -H "X-API-Key: ${API_KEY}" \
      -d "$JSON_PAYLOAD" | jq
  else
    curl -sS -X POST "${SVC_URL}/artist-ideas" \
      -H "Content-Type: application/json" \
      -d "$JSON_PAYLOAD" | jq
  fi
else
  if [[ -n "${SUGGESTIONS_API_KEY:-}" ]]; then
    API_KEY="$(RAW_KEY="$SUGGESTIONS_API_KEY" normalize_api_key)"
    curl -sS -X POST "${SVC_URL}/artist-ideas" \
      -H "Content-Type: application/json" \
      -H "X-API-Key: ${API_KEY}" \
      -d "$JSON_PAYLOAD"
  else
    curl -sS -X POST "${SVC_URL}/artist-ideas" \
      -H "Content-Type: application/json" \
      -d "$JSON_PAYLOAD"
  fi
  echo
fi
