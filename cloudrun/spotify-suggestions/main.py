import base64
import json
import os
import time
from typing import Optional

import httpx
from fastapi import FastAPI, Header, HTTPException

app = FastAPI()

SPOTIFY_CLIENT_ID = os.environ.get("SPOTIFY_CLIENT_ID")
SPOTIFY_CLIENT_SECRET = os.environ.get("SPOTIFY_CLIENT_SECRET")

if not SPOTIFY_CLIENT_ID:
    raise RuntimeError("SPOTIFY_CLIENT_ID is required")
if not SPOTIFY_CLIENT_SECRET:
    raise RuntimeError("SPOTIFY_CLIENT_SECRET is required")

SUGGESTIONS_API_KEY = os.environ.get("SUGGESTIONS_API_KEY")

GEMINI_API_KEY = os.environ.get("GEMINI_API_KEY")


def _require_api_key(x_api_key: Optional[str]) -> None:
    if SUGGESTIONS_API_KEY and x_api_key != SUGGESTIONS_API_KEY:
        raise HTTPException(status_code=401, detail="unauthorized")


def _extract_json_object(text: str) -> Optional[dict]:
    if not text:
        return None
    start = text.find("{")
    end = text.rfind("}")
    if start == -1 or end == -1 or end <= start:
        return None
    candidate = text[start : end + 1]
    try:
        value = json.loads(candidate)
    except Exception:
        return None
    return value if isinstance(value, dict) else None


def _sanitize_artist_names(raw: object, limit: int) -> list[str]:
    names: list[str] = []
    seen: set[str] = set()

    def consider(value: object) -> None:
        if not isinstance(value, str):
            return
        cleaned = value.strip()
        if not cleaned:
            return
        key = cleaned.casefold()
        if key in seen:
            return
        seen.add(key)
        names.append(cleaned)

    if isinstance(raw, dict):
        raw = raw.get("artists")

    if isinstance(raw, list):
        for item in raw:
            consider(item)
            if len(names) >= limit:
                break
        return names

    if isinstance(raw, str):
        # Fallback: one per line.
        for line in raw.splitlines():
            consider(line)
            if len(names) >= limit:
                break
        return names

    return names


async def _spotify_search_artist_summary(name: str) -> Optional[dict]:
    token = await _get_app_access_token()
    async with httpx.AsyncClient(timeout=20) as client:
        resp = await client.get(
            "https://api.spotify.com/v1/search",
            params={"type": "artist", "q": name, "limit": 1},
            headers={"Authorization": f"Bearer {token}"},
        )

    if resp.status_code != 200:
        raise HTTPException(status_code=502, detail=f"spotify_search_error: {resp.text}")

    data = resp.json() or {}
    items = (data.get("artists") or {}).get("items") or []
    if not items:
        return None

    item = items[0] or {}
    artist_id = item.get("id")
    if not artist_id:
        return None
    images = item.get("images") or []
    image_url = images[0].get("url") if images else None
    return {
        "id": artist_id,
        "name": item.get("name") or "",
        "followers": (item.get("followers") or {}).get("total"),
        "genres": item.get("genres") or [],
        "imageURL": image_url,
    }

_token_cache: dict[str, object] = {
    "access_token": None,
    "expires_at": 0.0,
}


def _basic_auth_header(client_id: str, client_secret: str) -> str:
    raw = f"{client_id}:{client_secret}".encode("utf-8")
    encoded = base64.b64encode(raw).decode("ascii")
    return f"Basic {encoded}"


async def _get_app_access_token() -> str:
    now = time.time()
    cached = _token_cache.get("access_token")
    expires_at = float(_token_cache.get("expires_at") or 0.0)
    if isinstance(cached, str) and cached and now < (expires_at - 30):
        return cached

    headers = {
        "Authorization": _basic_auth_header(SPOTIFY_CLIENT_ID, SPOTIFY_CLIENT_SECRET),
        "Content-Type": "application/x-www-form-urlencoded",
    }

    async with httpx.AsyncClient(timeout=20) as client:
        resp = await client.post(
            "https://accounts.spotify.com/api/token",
            data={"grant_type": "client_credentials"},
            headers=headers,
        )

    if resp.status_code != 200:
        raise HTTPException(status_code=502, detail=f"spotify_token_error: {resp.text}")

    payload = resp.json()
    access_token = payload.get("access_token")
    expires_in = int(payload.get("expires_in", 3600))

    if not access_token:
        raise HTTPException(status_code=502, detail=f"spotify_token_error: missing access_token ({payload})")

    _token_cache["access_token"] = access_token
    _token_cache["expires_at"] = now + expires_in
    return access_token


@app.get("/suggestions")
async def suggestions(
    q: str,
    limit: int = 6,
    x_api_key: Optional[str] = Header(default=None),
):
    _require_api_key(x_api_key)

    q = (q or "").strip()
    if len(q) < 2:
        return {"artists": []}

    safe_limit = max(1, min(int(limit), 10))

    token = await _get_app_access_token()
    async with httpx.AsyncClient(timeout=20) as client:
        resp = await client.get(
            "https://api.spotify.com/v1/search",
            params={"type": "artist", "q": q, "limit": safe_limit},
            headers={"Authorization": f"Bearer {token}"},
        )

    if resp.status_code != 200:
        raise HTTPException(status_code=502, detail=f"spotify_search_error: {resp.text}")

    data = resp.json() or {}
    items = (data.get("artists") or {}).get("items") or []

    artists = []
    for item in items:
        artist_id = item.get("id")
        if not artist_id:
            continue
        images = item.get("images") or []
        image_url = images[0].get("url") if images else None
        artists.append(
            {
                "id": artist_id,
                "name": item.get("name") or "",
                "followers": (item.get("followers") or {}).get("total"),
                "genres": item.get("genres") or [],
                "imageURL": image_url,
            }
        )

    return {"artists": artists}


@app.post("/artist-ideas")
async def artist_ideas(
    payload: dict,
    x_api_key: Optional[str] = Header(default=None),
):
    _require_api_key(x_api_key)

    prompt = str((payload or {}).get("prompt") or "").strip()
    if not prompt:
        raise HTTPException(status_code=400, detail="missing_prompt")

    try:
        requested_count = int((payload or {}).get("artistCount") or 0)
    except Exception:
        requested_count = 0
    safe_count = max(1, min(requested_count or 20, 30))

    if not GEMINI_API_KEY:
        raise HTTPException(status_code=501, detail="gemini_not_configured")

    system_instructions = (
        "Return JSON only. No markdown. "
        "Schema: {\"artists\": [\"Artist Name\", ...]}. "
        "Provide exactly the requested number when possible."
    )

    gemini_body = {
        "contents": [
            {
                "role": "user",
                "parts": [
                    {"text": system_instructions},
                    {"text": f"Artist count: {safe_count}"},
                    {"text": f"Prompt: {prompt}"},
                ],
            }
        ],
        "generationConfig": {
            "temperature": 0.8,
            "maxOutputTokens": 1024,
            "responseMimeType": "application/json",
        },
    }

    url = (
        "https://generativelanguage.googleapis.com/v1beta/models/"
        "gemini-flash-latest:generateContent"
    )

    async with httpx.AsyncClient(timeout=30) as client:
        resp = await client.post(url, params={"key": GEMINI_API_KEY}, json=gemini_body)

    if resp.status_code != 200:
        raise HTTPException(status_code=502, detail=f"gemini_error: {resp.text}")

    gemini_payload = resp.json() or {}
    candidates = gemini_payload.get("candidates") or []
    text = ""
    if candidates:
        content = (candidates[0] or {}).get("content") or {}
        parts = content.get("parts") or []
        if parts:
            text = str((parts[0] or {}).get("text") or "")

    parsed = _extract_json_object(text)
    if parsed is None:
        # Some responses may still not be strict JSON; try best-effort.
        parsed = {"artists": text}

    names = _sanitize_artist_names(parsed, limit=safe_count)

    verified: list[dict] = []
    seen_ids: set[str] = set()
    for name in names:
        summary = await _spotify_search_artist_summary(name)
        if not summary:
            continue
        artist_id = str(summary.get("id") or "")
        if not artist_id or artist_id in seen_ids:
            continue
        seen_ids.add(artist_id)
        verified.append(summary)
        if len(verified) >= safe_count:
            break

    return {"artists": verified}
