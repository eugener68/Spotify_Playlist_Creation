import base64
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
    if SUGGESTIONS_API_KEY and x_api_key != SUGGESTIONS_API_KEY:
        raise HTTPException(status_code=401, detail="unauthorized")

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
