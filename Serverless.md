# Cloud Run Serverless Plan

## Goal

Provide a secure, scalable endpoint that turns user prompts into artist suggestions using Googles Gemini API, without exposing the API key inside the client app.

## Overview

1. **Cloud Run Service**: Deploy a lightweight HTTPS API (Node, Python, or Go) to Cloud Run.
2. **Secret Storage**: Store the Gemini API key in Secret Manager and load it as an environment variable at runtime.
3. **Request Contract**: `POST /artist-ideas` with `{ prompt, artistCount, userId }`.
4. **Gemini Call**: Service calls `gemini-flash-latest` via `https://generativelanguage.googleapis.com/v1beta/models/gemini-flash-latest:generateContent?key=API_KEY` and requests JSON output `{ "artists": [ ... ] }`.
5. **Response**: Return the sanitized artist list to the client as `{ "artists": [ ... ] }`.
6. **Security**: Require a shared client secret or signed token, log usage, and rate-limit by user or IP.
7. **App Integration**: iOS app hits this Cloud Run endpoint when the user taps "Generate with AI" and merges the returned artists into the manual list.

## Next Steps

- Scaffold the Cloud Run service with the single `/artist-ideas` handler.
- Wire Secret Manager + environment variables for the Gemini key.
- Implement auth/rate-limiting logic.
- Add Swift networking layer to call the new endpoint and integrate with the UI.
