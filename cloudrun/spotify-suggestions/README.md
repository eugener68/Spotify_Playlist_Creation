# Cloud Run: Spotify Suggestions (Client Credentials)

This service exposes a single endpoint that returns artist suggestions using Spotify Web API search.

## Endpoint

- `GET /suggestions?q=<query>&limit=<n>`
- Optional header: `x-api-key: <SUGGESTIONS_API_KEY>`

Response:

```json
{ "artists": [{"id":"...","name":"...","followers":123,"genres":[],"imageURL":"..."}] }
```

## Required env vars

- `SPOTIFY_CLIENT_ID`
- `SPOTIFY_CLIENT_SECRET`

Optional:
- `SUGGESTIONS_API_KEY` (recommended)

## Deploy (gcloud)

```bash
gcloud config set project YOUR_PROJECT_ID

gcloud services enable run.googleapis.com secretmanager.googleapis.com cloudbuild.googleapis.com

printf '%s' "YOUR_SPOTIFY_CLIENT_SECRET" | gcloud secrets create SPOTIFY_CLIENT_SECRET --data-file=-
# if it already exists:
# printf '%s' "..." | gcloud secrets versions add SPOTIFY_CLIENT_SECRET --data-file=-

# optional API key
printf '%s' "YOUR_LONG_RANDOM_API_KEY" | gcloud secrets create SUGGESTIONS_API_KEY --data-file=-
# or versions add ...

gcloud run deploy spotify-suggestions \
  --source . \
  --region us-central1 \
  --allow-unauthenticated \
  --set-env-vars SPOTIFY_CLIENT_ID=YOUR_SPOTIFY_CLIENT_ID \
  --set-secrets SPOTIFY_CLIENT_SECRET=SPOTIFY_CLIENT_SECRET:latest \
  --set-secrets SUGGESTIONS_API_KEY=SUGGESTIONS_API_KEY:latest
```

## Test

```bash
curl -H "x-api-key: YOUR_LONG_RANDOM_API_KEY" \
  "https://YOUR_RUN_URL/suggestions?q=A-h&limit=6"
```
