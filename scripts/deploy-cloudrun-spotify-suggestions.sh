#!/usr/bin/env bash
set -euo pipefail

# Deploy the Cloud Run backend in cloudrun/spotify-suggestions.
# This builds a container image with Cloud Build, then deploys it to Cloud Run.
# It does NOT change environment variables or secrets on the service unless you add flags.
#
# Usage:
#   ./scripts/deploy-cloudrun-spotify-suggestions.sh
#   GCP_PROJECT=my-project GCP_REGION=europe-west1 SERVICE=spotify-suggestions ./scripts/deploy-cloudrun-spotify-suggestions.sh

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SOURCE_DIR="$ROOT_DIR/cloudrun/spotify-suggestions"

if ! command -v gcloud >/dev/null 2>&1; then
  echo "gcloud not found. Install Google Cloud SDK first." >&2
  exit 1
fi

PROJECT_ID="${GCP_PROJECT:-}"
if [[ -z "$PROJECT_ID" ]]; then
  PROJECT_ID="$(gcloud config get-value project 2>/dev/null || true)"
fi
if [[ -z "$PROJECT_ID" || "$PROJECT_ID" == "(unset)" ]]; then
  echo "GCP project is not set. Either run: gcloud config set project <PROJECT_ID>" >&2
  echo "or pass GCP_PROJECT=<PROJECT_ID> when running this script." >&2
  exit 1
fi

REGION="${GCP_REGION:-us-central1}"
SERVICE="${SERVICE:-spotify-suggestions}"

REV="$(git -C "$ROOT_DIR" rev-parse --short HEAD 2>/dev/null || date +%Y%m%d%H%M%S)"
IMAGE="gcr.io/${PROJECT_ID}/${SERVICE}:${REV}"

echo "Deploying Cloud Run service: $SERVICE"
echo "Project: $PROJECT_ID"
echo "Region:  $REGION"
echo "Image:   $IMAGE"
echo "Source:  $SOURCE_DIR"
echo

# Build and push image.
gcloud builds submit "$SOURCE_DIR" --tag "$IMAGE" --project "$PROJECT_ID"

# Deploy new revision (keeps existing env vars/secrets by default).
gcloud run deploy "$SERVICE" \
  --image "$IMAGE" \
  --region "$REGION" \
  --project "$PROJECT_ID" \
  --platform managed

echo
echo "Done. Current service URL:"
gcloud run services describe "$SERVICE" --region "$REGION" --project "$PROJECT_ID" --format='value(status.url)'
