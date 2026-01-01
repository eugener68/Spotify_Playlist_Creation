import base64
import hmac
import json
import os
import re
import time
from typing import Optional

import httpx
import jwt
from fastapi import FastAPI, Header, HTTPException

app = FastAPI()

SPOTIFY_CLIENT_ID = os.environ.get("SPOTIFY_CLIENT_ID")
SPOTIFY_CLIENT_SECRET = os.environ.get("SPOTIFY_CLIENT_SECRET")

SUGGESTIONS_API_KEY = os.environ.get("SUGGESTIONS_API_KEY")

GEMINI_API_KEY = os.environ.get("GEMINI_API_KEY")

APPLE_MUSIC_TEAM_ID = os.environ.get("APPLE_MUSIC_TEAM_ID")
APPLE_MUSIC_KEY_ID = os.environ.get("APPLE_MUSIC_KEY_ID")
APPLE_MUSIC_PRIVATE_KEY_B64 = os.environ.get("APPLE_MUSIC_PRIVATE_KEY_B64")
APPLE_MUSIC_PRIVATE_KEY_FILE = os.environ.get("APPLE_MUSIC_PRIVATE_KEY_FILE")
APPLE_MUSIC_BACKEND_API_KEY = os.environ.get("APPLE_MUSIC_BACKEND_API_KEY")
try:
    APPLE_MUSIC_TOKEN_TTL_SECONDS = int(os.environ.get("APPLE_MUSIC_TOKEN_TTL_SECONDS", "300"))
except Exception:
    APPLE_MUSIC_TOKEN_TTL_SECONDS = 300

# Gemini configuration (override via Cloud Run env vars).
GEMINI_MODEL = os.environ.get("GEMINI_MODEL", "gemini-flash-latest")
try:
    GEMINI_TEMPERATURE = float(os.environ.get("GEMINI_TEMPERATURE", "0.6"))
except Exception:
    GEMINI_TEMPERATURE = 0.6
try:
    GEMINI_MAX_OUTPUT_TOKENS = int(os.environ.get("GEMINI_MAX_OUTPUT_TOKENS", "2048"))
except Exception:
    GEMINI_MAX_OUTPUT_TOKENS = 2048

# Oversampling helps fill the verified list when some generated names don't exist on Spotify.
# Too much oversampling can increase the chance of truncation.
try:
    ARTIST_IDEAS_OVERSAMPLE = float(os.environ.get("ARTIST_IDEAS_OVERSAMPLE", "1.5"))
except Exception:
    ARTIST_IDEAS_OVERSAMPLE = 1.5
try:
    ARTIST_IDEAS_MAX_CANDIDATES = int(os.environ.get("ARTIST_IDEAS_MAX_CANDIDATES", "30"))
except Exception:
    ARTIST_IDEAS_MAX_CANDIDATES = 30


def _require_api_key(x_api_key: Optional[str]) -> None:
    if SUGGESTIONS_API_KEY and x_api_key != SUGGESTIONS_API_KEY:
        raise HTTPException(status_code=401, detail="unauthorized")


def _require_apple_music_api_key(x_api_key: Optional[str]) -> None:
    expected = APPLE_MUSIC_BACKEND_API_KEY
    if not expected:
        raise HTTPException(status_code=501, detail="apple_music_not_configured")
    provided = x_api_key or ""
    if not hmac.compare_digest(provided, expected):
        raise HTTPException(status_code=401, detail="unauthorized")


def _load_apple_music_private_key_pem() -> str:
    if APPLE_MUSIC_PRIVATE_KEY_FILE:
        try:
            with open(APPLE_MUSIC_PRIVATE_KEY_FILE, "r", encoding="utf-8") as f:
                value = f.read().strip()
        except Exception as exc:
            raise HTTPException(status_code=501, detail=f"apple_music_key_read_error: {exc}")
        if value:
            return value

    if APPLE_MUSIC_PRIVATE_KEY_B64:
        try:
            decoded = base64.b64decode(APPLE_MUSIC_PRIVATE_KEY_B64).decode("utf-8")
        except Exception as exc:
            raise HTTPException(status_code=501, detail=f"apple_music_key_decode_error: {exc}")
        decoded = (decoded or "").strip()
        if decoded:
            return decoded

    raise HTTPException(status_code=501, detail="apple_music_not_configured")


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


def _extract_artist_strings_from_text(text: str, limit: int) -> list[str]:
    """Best-effort extraction of artist-like strings from partially valid JSON.

    Gemini sometimes returns truncated JSON (finishReason=MAX_TOKENS). In that case,
    json.loads() will fail, but we can still salvage quoted strings.
    """
    if not text:
        return []

    # Pull out quoted strings. This will include the key name "artists" as well.
    matches = re.findall(r"\"([^\"\\]*(?:\\.[^\"\\]*)*)\"", text)
    results: list[str] = []
    seen: set[str] = set()
    for raw in matches:
        if not raw:
            continue
        value = raw.strip()
        if not value:
            continue

        # Unescape simple sequences that appear in JSON-ish text.
        value = value.replace("\\\"", '"').replace("\\n", " ")

        # Drop obvious non-values.
        if value.casefold() in {"artists", "artist"}:
            continue
        if any(ch in value for ch in (":", "[", "]", "{", "}")):
            continue

        key = value.casefold()
        if key in seen:
            continue
        seen.add(key)
        results.append(value)
        if len(results) >= limit:
            break
    return results


def _sanitize_artist_names(raw: object, limit: int) -> list[str]:
    names: list[str] = []
    seen: set[str] = set()

    def consider(value: object) -> None:
        if not isinstance(value, str):
            return
        cleaned = value.strip()
        if not cleaned:
            return

        cleaned = cleaned.strip("\"'")
        cleaned = cleaned.strip(" ,;")
        if not cleaned:
            return

        # Remove common placeholder wrappers.
        for left, right in (("{", "}"), ("(", ")"), ("[", "]")):
            if cleaned.startswith(left) and cleaned.endswith(right) and len(cleaned) > 2:
                cleaned = cleaned[1:-1].strip()

        # Reject suspicious tokens often produced by LLMs.
        if any(ch in cleaned for ch in ("{", "}")):
            return
        if cleaned.casefold() in {"artists", "artist"}:
            return
        if any(ch in cleaned for ch in (":", "[", "]")):
            return
        if len(cleaned) > 80:
            return
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


def _tokens_for_match(value: str) -> list[str]:
    return [t for t in re.findall(r"[a-z0-9]+", (value or "").casefold()) if len(t) > 2]


def _is_reasonable_match(query: str, matched_name: str) -> bool:
    # Ensure Spotify's top hit is actually close to the requested artist name.
    # This prevents garbage queries like 'artists": [' from matching popular artists.
    q_tokens = _tokens_for_match(query)
    if not q_tokens:
        return False
    m_tokens = set(_tokens_for_match(matched_name))
    if not m_tokens:
        return False
    return all(t in m_tokens for t in q_tokens)


async def _gemini_generate_artist_names(
    *,
    prompt: str,
    candidate_count: int,
    model: str,
    temperature: float,
    avoid_names: list[str] | None = None,
) -> tuple[list[str], dict, str]:
    if not GEMINI_API_KEY:
        raise HTTPException(status_code=501, detail="gemini_not_configured")

    avoid_clause = ""
    if avoid_names:
        # Keep this compact to avoid ballooning the prompt.
        compact = ", ".join(avoid_names[:50])
        avoid_clause = f" Do not include any of these artists: {compact}."

    system_instructions = (
        "Return JSON only. No markdown. "
        "Schema: {\"artists\": [\"Artist Name\", ...]}. "
        "Provide exactly the requested number when possible. "
        "Only include artist names that match the user's prompt constraints (genre/era/language/nationality). "
        "Do not include unrelated artists. Do not include placeholders like {Parentheses}, brackets, or notes." + avoid_clause
    )

    gemini_body = {
        "contents": [
            {
                "role": "user",
                "parts": [
                    {"text": system_instructions},
                    {"text": f"Artist count: {candidate_count}"},
                    {"text": f"Prompt: {prompt}"},
                ],
            }
        ],
        "generationConfig": {
            "temperature": temperature,
            "maxOutputTokens": GEMINI_MAX_OUTPUT_TOKENS,
            "responseMimeType": "application/json",
        },
    }

    url = f"https://generativelanguage.googleapis.com/v1beta/models/{model}:generateContent"

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
        if isinstance(parts, list) and parts:
            text_chunks: list[str] = []
            for part in parts:
                if isinstance(part, dict) and isinstance(part.get("text"), str):
                    chunk = part.get("text") or ""
                    if chunk:
                        text_chunks.append(chunk)
            text = "".join(text_chunks)

    parsed = _extract_json_object(text)
    if parsed is None:
        extracted = _extract_artist_strings_from_text(text, limit=candidate_count)
        parsed = {"artists": extracted}

    names = _sanitize_artist_names(parsed, limit=candidate_count)
    return names, gemini_payload, text

_token_cache: dict[str, object] = {
    "access_token": None,
    "expires_at": 0.0,
}

_apple_music_token_cache: dict[str, object] = {
    "token": None,
    "expires_at": 0.0,
}


def _basic_auth_header(client_id: str, client_secret: str) -> str:
    raw = f"{client_id}:{client_secret}".encode("utf-8")
    encoded = base64.b64encode(raw).decode("ascii")
    return f"Basic {encoded}"


async def _get_app_access_token() -> str:
    if not SPOTIFY_CLIENT_ID or not SPOTIFY_CLIENT_SECRET:
        raise HTTPException(status_code=501, detail="spotify_not_configured")

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


def _get_apple_music_developer_token() -> str:
    if not APPLE_MUSIC_TEAM_ID or not APPLE_MUSIC_KEY_ID:
        raise HTTPException(status_code=501, detail="apple_music_not_configured")

    now = int(time.time())
    cached = _apple_music_token_cache.get("token")
    expires_at = int(float(_apple_music_token_cache.get("expires_at") or 0.0))
    if isinstance(cached, str) and cached and now < (expires_at - 30):
        return cached

    private_key_pem = _load_apple_music_private_key_pem()

    ttl = max(60, min(int(APPLE_MUSIC_TOKEN_TTL_SECONDS or 300), 3600))
    exp = now + ttl
    payload = {"iss": APPLE_MUSIC_TEAM_ID, "iat": now, "exp": exp}

    try:
        token = jwt.encode(payload, private_key_pem, algorithm="ES256", headers={"kid": APPLE_MUSIC_KEY_ID})
    except Exception as exc:
        raise HTTPException(status_code=502, detail=f"apple_music_jwt_error: {exc}")

    _apple_music_token_cache["token"] = token
    _apple_music_token_cache["expires_at"] = float(exp)
    return token


@app.get("/apple-music/developer-token")
async def apple_music_developer_token(x_api_key: Optional[str] = Header(default=None)):
    _require_apple_music_api_key(x_api_key)
    return {"token": _get_apple_music_developer_token()}


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
    debug = bool((payload or {}).get("debug") or False)

    # Ask Gemini for more candidates than we ultimately return.
    # Many names will fail Spotify verification (misspellings, non-artists, etc).
    # Oversampling improves fill-rate but too much increases truncation risk.
    candidate_count = min(
        max(int(round(safe_count * ARTIST_IDEAS_OVERSAMPLE)), safe_count + 10),
        ARTIST_IDEAS_MAX_CANDIDATES,
    )

    # Optional request overrides (useful for debugging). Kept conservative.
    try:
        requested_candidate_count = int((payload or {}).get("candidateCount") or 0)
    except Exception:
        requested_candidate_count = 0
    if requested_candidate_count > 0:
        candidate_count = max(safe_count, min(requested_candidate_count, ARTIST_IDEAS_MAX_CANDIDATES))

    requested_model = str((payload or {}).get("model") or "").strip()
    model = GEMINI_MODEL
    if requested_model:
        # Basic validation to avoid weird injection/path issues.
        if re.match(r"^[a-zA-Z0-9._\-]+$", requested_model) and len(requested_model) <= 64:
            model = requested_model

    names, gemini_payload, text = await _gemini_generate_artist_names(
        prompt=prompt,
        candidate_count=candidate_count,
        model=model,
        temperature=GEMINI_TEMPERATURE,
        avoid_names=None,
    )

    verified: list[dict] = []
    seen_ids: set[str] = set()
    debug_verification: list[dict] = []
    for name in names:
        summary = await _spotify_search_artist_summary(name)
        if not summary:
            if debug:
                debug_verification.append({"query": name, "status": "not_found"})
            continue
        if not _is_reasonable_match(name, str(summary.get("name") or "")):
            if debug:
                debug_verification.append({"query": name, "status": "mismatch", "matched": summary})
            continue
        artist_id = str(summary.get("id") or "")
        if not artist_id:
            if debug:
                debug_verification.append({"query": name, "status": "missing_id"})
            continue
        if artist_id in seen_ids:
            if debug:
                debug_verification.append({"query": name, "status": "duplicate_id", "matched": summary})
            continue
        seen_ids.add(artist_id)
        verified.append(summary)
        if debug:
            debug_verification.append({"query": name, "status": "ok", "matched": summary})
        if len(verified) >= safe_count:
            break

    # If we under-filled (common when Gemini returns typos/obscure names), do one retry with:
    # - more candidates
    # - lower temperature
    # - an explicit avoid list
    retry_meta: dict | None = None
    retry_text: str | None = None
    retry_names: list[str] | None = None
    if len(verified) < safe_count:
        retry_candidate_count = min(
            ARTIST_IDEAS_MAX_CANDIDATES,
            max(candidate_count * 2, safe_count + 10),
        )
        retry_names, retry_meta_payload, retry_text = await _gemini_generate_artist_names(
            prompt=prompt,
            candidate_count=retry_candidate_count,
            model=model,
            temperature=min(0.2, GEMINI_TEMPERATURE),
            avoid_names=[v.get("name", "") for v in verified if isinstance(v, dict) and v.get("name")],
        )
        retry_meta = retry_meta_payload
        for name in (retry_names or []):
            if len(verified) >= safe_count:
                break
            summary = await _spotify_search_artist_summary(name)
            if not summary:
                if debug:
                    debug_verification.append({"query": name, "status": "not_found"})
                continue
            if not _is_reasonable_match(name, str(summary.get("name") or "")):
                if debug:
                    debug_verification.append({"query": name, "status": "mismatch", "matched": summary})
                continue
            artist_id = str(summary.get("id") or "")
            if not artist_id:
                if debug:
                    debug_verification.append({"query": name, "status": "missing_id"})
                continue
            if artist_id in seen_ids:
                if debug:
                    debug_verification.append({"query": name, "status": "duplicate_id", "matched": summary})
                continue
            seen_ids.add(artist_id)
            verified.append(summary)
            if debug:
                debug_verification.append({"query": name, "status": "ok", "matched": summary})

    response: dict = {"artists": verified}
    if debug:
        candidates = gemini_payload.get("candidates") or []
        prompt_feedback = gemini_payload.get("promptFeedback")
        first_candidate = candidates[0] if candidates else None
        # Keep this small/safe: enough to diagnose why Gemini returned empty text.
        gemini_meta = {
            "candidateCount": len(candidates),
            "finishReason": (first_candidate or {}).get("finishReason") if isinstance(first_candidate, dict) else None,
            "promptFeedback": prompt_feedback,
        }
        response["debug"] = {
            "prompt": prompt,
            "requestedArtistCount": requested_count,
            "safeArtistCount": safe_count,
            "candidateCount": candidate_count,
            "geminiText": text,
            "geminiMeta": gemini_meta,
            "sanitizedNames": names,
            "verification": debug_verification,
            "verifiedCount": len(verified),
            "retry": {
                "attempted": bool(retry_names),
                "candidateCount": len((retry_meta or {}).get("candidates") or []) if isinstance(retry_meta, dict) else None,
                "geminiText": retry_text,
                "sanitizedNames": retry_names,
            },
        }
    return response
