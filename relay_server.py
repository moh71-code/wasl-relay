#!/usr/bin/env python3
"""
WASL Secure Relay Server — Render-Compatible Version
Privacy-by-Design | Zero-Knowledge | In-Memory Only

Supports TWO connection modes:
  1. Path-based: wss://host/ws/{user_id}   (registers after challenge-response)
  2. Message-based: wss://host/ws/anonymous + {type: register, ...}

Registration is authenticated: the server sends a random challenge nonce on
connect and the client must return an Ed25519 signature over
"wasl-register|<user_id>|<nonce>" proving ownership of its identity key.

Render sets the PORT env variable automatically.
"""

import asyncio
import base64
import collections
import hashlib
import json
import logging
import os
import secrets
import time
from typing import Dict, List, Tuple

from fastapi import FastAPI, HTTPException, Request, WebSocket, WebSocketDisconnect
from fastapi.responses import FileResponse, JSONResponse

try:
    from cryptography.exceptions import InvalidSignature
    from cryptography.hazmat.primitives.asymmetric.ed25519 import (
        Ed25519PublicKey,
    )
    _ED25519_AVAILABLE = True
except ImportError:
    _ED25519_AVAILABLE = False

logging.basicConfig(
    level=logging.INFO,
    format="[%(asctime)s] [WASL] %(message)s",
    datefmt="%Y-%m-%d %H:%M:%S",
)
logger = logging.getLogger("wasl_relay")

# ── Firebase Cloud Messaging (push wake-up) ─────────────────────────────────
# Optional: enabled when FIREBASE_SERVICE_ACCOUNT holds the service-account
# JSON (Render secret env var). Pushes are data-only {type:"wake"} nudges —
# they never carry sender ids, ciphertext, or any metadata.
_FCM_READY = False
try:
    import firebase_admin
    from firebase_admin import credentials as _fb_credentials
    from firebase_admin import messaging as _fb_messaging

    _sa_json = os.environ.get("FIREBASE_SERVICE_ACCOUNT", "")
    if _sa_json.strip():
        firebase_admin.initialize_app(
            _fb_credentials.Certificate(json.loads(_sa_json)))
        _FCM_READY = True
        logger.info("FCM push wake-up enabled")
except ImportError:
    logger.warning("firebase-admin missing — push wake-up disabled")
except Exception as e:
    logger.error("FCM init failed: %s", e)

app = FastAPI(title="WASL E2EE Relay", docs_url=None, redoc_url=None)

# user_id -> WebSocket (only AUTHENTICATED clients live here)
active_clients: Dict[str, WebSocket] = {}

# user_id -> bound Ed25519 public key (base64). Trust-on-first-use within the
# process lifetime: once bound, a user_id can only be claimed by the same key.
user_bindings: Dict[str, str] = {}

# Ephemeral offline queue: user_id -> [(unix_ts, raw JSON string)] (RAM only)
offline_queue: Dict[str, List[Tuple[float, str]]] = collections.defaultdict(list)

# user_id -> FCM device token (RAM only; clients re-push it on every connect)
fcm_tokens: Dict[str, str] = {}

# Frame types that must NOT wake the recipient's device — acks, typing
# indicators and control frames are silently queued/delivered only.
_SILENT_TYPES = {
    "ping", "pong", "delivery_ack", "read_ack", "typing",
    "delete_message", "fcm_token",
}

MAX_QUEUE = 300

# Per-recipient queued bytes cap — file frames are 64KB chunks, but a 100MB
# file fans out to ~137MB of base64 payloads; the budget must hold one full
# file for offline recipients or tail chunks would be dropped mid-transfer.
MAX_QUEUE_BYTES = 160 * 1024 * 1024

# Hard frame size cap — matches the per-recipient queue byte budget, so an
# offline_file envelope (~47MB raw → ~64MB base64) is the largest legit frame.
MAX_FRAME_BYTES = 64 * 1024 * 1024

# Queued ciphertexts expire after 24 hours — recipients who never come online
# must not accumulate data in RAM forever.
QUEUE_TTL_SECONDS = 24 * 60 * 60

# ── Closed update channel ────────────────────────────────────────────────────
# Release files live on a persistent disk (UPDATE_DIR) and can ONLY be reached
# by an authenticated WS client that requests a one-time download token — the
# raw URL is never usable on its own, and tokens are single-use + expire.
UPDATE_DIR = os.environ.get("UPDATE_DIR", "/data/updates")
try:
    os.makedirs(UPDATE_DIR, exist_ok=True)
except OSError:
    # Disk not mounted (or fs not writable) — fall back to an app-local dir.
    # It is EPHEMERAL (lost on redeploy) but keeps the channel working until
    # a persistent disk is attached in the Render dashboard.
    UPDATE_DIR = os.path.join(
        os.path.dirname(os.path.abspath(__file__)), "wasl_updates")
    os.makedirs(UPDATE_DIR, exist_ok=True)
    logger.warning(
        "Persistent update dir unavailable — using ephemeral %s", UPDATE_DIR)

ADMIN_TOKEN = os.environ.get("ADMIN_TOKEN", "")
UPDATE_TOKEN_TTL = 600          # seconds
UPDATE_MAX_BYTES = 200 * 1024 * 1024

# token -> expiry unix ts (RAM only; a restart just forces a fresh check)
_download_tokens: Dict[str, float] = {}


def _uid(user_id: str) -> str:
    """Log-safe user handle — never print raw user_ids (metadata minimization)."""
    return "u#" + hashlib.sha256(user_id.encode()).hexdigest()[:10]


def _prune_queue(user_id: str) -> None:
    """Drop expired entries for a user (lazy cleanup on access)."""
    q = offline_queue.get(user_id)
    if not q:
        return
    cutoff = time.time() - QUEUE_TTL_SECONDS
    fresh = [entry for entry in q if entry[0] >= cutoff]
    if fresh:
        offline_queue[user_id] = fresh
    else:
        offline_queue.pop(user_id, None)


def _verify_register(user_id: str, public_key_b64: str, nonce: str,
                     signature_b64: str) -> bool:
    """Verify the Ed25519 challenge-response signature for registration."""
    if not _ED25519_AVAILABLE:
        logger.error("cryptography package missing — cannot verify registrations")
        return False
    try:
        pub = Ed25519PublicKey.from_public_bytes(base64.b64decode(public_key_b64))
        msg = f"wasl-register|{user_id}|{nonce}".encode()
        pub.verify(base64.b64decode(signature_b64), msg)
        return True
    except InvalidSignature:
        return False
    except Exception:
        return False


async def _send_wake_push(recipient_id: str, token: str) -> None:
    """Send a content-free high-priority data push that wakes the app.

    The payload is only {"type": "wake"} — no sender, no metadata — so the
    zero-knowledge property holds even through Google's push channel.
    """
    try:
        message = _fb_messaging.Message(
            token=token,
            data={"type": "wake"},
            android=_fb_messaging.AndroidConfig(priority="high"),
            apns=_fb_messaging.APNSConfig(
                headers={"apns-priority": "5"},
                payload=_fb_messaging.APNSPayload(
                    aps=_fb_messaging.Aps(content_available=True)),
            ),
        )
        await asyncio.to_thread(_fb_messaging.send, message)
        logger.info("Sent wake push to %s", _uid(recipient_id))
    except Exception as e:
        if "Unregistered" in type(e).__name__ or "NotRegistered" in str(e):
            # Token gone stale — stop paying FCM calls for a dead device.
            fcm_tokens.pop(recipient_id, None)
            logger.info("Dropped stale FCM token for %s", _uid(recipient_id))
        else:
            logger.warning("Wake push failed for %s: %s",
                           _uid(recipient_id), type(e).__name__)


def _maybe_wake(recipient_id: str, msg_type: str) -> None:
    """Fire-and-forget wake push when buffering a real message for an
    offline user. Throttled: only fires on the FIRST item entering an
    empty queue — the rest ride the same wake (queue flushes whole)."""
    if not _FCM_READY or msg_type in _SILENT_TYPES:
        return
    token = fcm_tokens.get(recipient_id)
    if token:
        asyncio.create_task(_send_wake_push(recipient_id, token))


async def _deliver(recipient_id: str, payload: str, msg_type: str = "msg") -> bool:
    """Try to deliver to connected client, else buffer in RAM queue."""
    ws = active_clients.get(recipient_id)
    if ws:
        try:
            await ws.send_text(payload)
            return True
        except Exception:
            active_clients.pop(recipient_id, None)

    q = offline_queue[recipient_id]
    _prune_queue(recipient_id)
    q = offline_queue[recipient_id]
    queued_bytes = sum(len(entry[1]) for entry in q)
    if len(q) < MAX_QUEUE and queued_bytes + len(payload) <= MAX_QUEUE_BYTES:
        was_empty = not q
        q.append((time.time(), payload))
        logger.info("Buffered [%s] for offline %s (queue=%d)",
                    msg_type, _uid(recipient_id), len(q))
        if was_empty:
            _maybe_wake(recipient_id, msg_type)
    else:
        logger.warning("Queue full for %s, dropping [%s]",
                       _uid(recipient_id), msg_type)
    return False


async def _flush_queue(user_id: str, ws: WebSocket):
    """Flush buffered messages when an AUTHENTICATED user comes online."""
    _prune_queue(user_id)
    pending = offline_queue.pop(user_id, [])
    if pending:
        logger.info("Flushing %d queued message(s) to %s",
                    len(pending), _uid(user_id))
        for _ts, raw in pending:
            try:
                await ws.send_text(raw)
            except Exception:
                break


async def _handle_ws(websocket: WebSocket, user_id_from_path: str = ""):
    """Core WebSocket handler shared by both path-based and root endpoints."""
    await websocket.accept()
    current_user_id: str = ""
    authenticated = False

    # Every connection gets a unique registration challenge.
    nonce = base64.b64encode(os.urandom(32)).decode()
    await websocket.send_text(json.dumps({"type": "challenge", "nonce": nonce}))

    try:
        async for raw in websocket.iter_text():
            if len(raw) > MAX_FRAME_BYTES:
                logger.warning("Oversized frame dropped (%d bytes)", len(raw))
                continue
            try:
                data = json.loads(raw)
            except json.JSONDecodeError:
                continue

            msg_type = data.get("type", "")

            # Heartbeat
            if msg_type == "ping":
                await websocket.send_text(json.dumps({"type": "pong"}))
                continue
            if msg_type == "pong":
                continue

            # Authenticated registration (challenge-response)
            if msg_type == "register":
                uid = str(data.get("user_id", "")).strip().upper()
                pub_b64 = str(data.get("public_key", ""))
                sig_b64 = str(data.get("signature", ""))
                echoed = str(data.get("nonce", ""))
                if not uid:
                    continue
                if echoed != nonce or not _verify_register(
                        uid, pub_b64, echoed, sig_b64):
                    logger.warning("Rejected unauthenticated register for %s",
                                   _uid(uid))
                    await websocket.send_text(json.dumps(
                        {"type": "register_error", "reason": "auth_failed"}))
                    try:
                        await websocket.close(code=4003)
                    except Exception:
                        pass
                    return
                bound = user_bindings.get(uid)
                if bound is not None and bound != pub_b64:
                    logger.warning("Rejected key mismatch for %s", _uid(uid))
                    await websocket.send_text(json.dumps(
                        {"type": "register_error", "reason": "key_mismatch"}))
                    try:
                        await websocket.close(code=4003)
                    except Exception:
                        pass
                    return
                user_bindings.setdefault(uid, pub_b64)

                # Move an old connection registration away if the socket moved
                if (current_user_id and current_user_id in active_clients
                        and active_clients[current_user_id] is websocket):
                    active_clients.pop(current_user_id, None)

                current_user_id = uid
                authenticated = True
                active_clients[uid] = websocket
                logger.info("Authenticated register: %s (active=%d)",
                            _uid(uid), len(active_clients))

                # Confirm auth BEFORE flushing — the client only starts
                # sending app frames once it sees 'registered', closing the
                # race where pre-auth frames were silently dropped.
                await websocket.send_text(json.dumps({"type": "registered"}))

                await _flush_queue(uid, websocket)
                continue

            # Everything below requires an authenticated registration.
            if not authenticated:
                continue

            # Zero-trust: the relay OWNS sender identity. A client can never
            # claim to be another user_id — overwrite sender_id with the
            # authenticated identity and re-serialize what we forward, so a
            # forged sender_id can never reach a recipient (spoofed acks,
            # fake pair_accept key rotation, premature-expiry read_ack).
            if "sender_id" in data:
                data["sender_id"] = current_user_id
                raw = json.dumps(data)

            # Push wake-up token — bound to the authenticated user_id.
            if msg_type == "fcm_token":
                token = str(data.get("token", "")).strip()
                if token and current_user_id:
                    fcm_tokens[current_user_id] = token
                continue

            # Authenticated presence query — only ever replies with online/offline.
            if msg_type == "presence_query":
                target = str(data.get("recipient_id", "")).strip().upper()
                request_id = data.get("request_id", "")
                if target:
                    await websocket.send_text(json.dumps({
                        "type": "presence_info",
                        "request_id": request_id,
                        "recipient_id": target,
                        "online": target in active_clients,
                    }))
                continue

            # Closed update channel — the manifest rides the authenticated
            # WS frame, and a single-use download token is minted for the APK.
            # No public URL ever exists: a token expires in minutes and is
            # consumed on first use, so sharing a link is impossible.
            if msg_type == "update_check":
                manifest = None
                token = ""
                mpath = os.path.join(UPDATE_DIR, "version.json")
                apk_path = os.path.join(UPDATE_DIR, "wasl-release.apk")
                try:
                    if os.path.isfile(mpath) and os.path.isfile(apk_path):
                        with open(mpath, encoding="utf-8") as mf:
                            manifest = json.loads(mf.read())
                        # Lazy sweep of expired tokens while we're here.
                        now = time.time()
                        for t, exp in list(_download_tokens.items()):
                            if exp < now:
                                _download_tokens.pop(t, None)
                        token = secrets.token_urlsafe(32)
                        _download_tokens[token] = now + UPDATE_TOKEN_TTL
                except Exception:
                    manifest = None
                    token = ""
                await websocket.send_text(json.dumps({
                    "type": "update_info",
                    "manifest": manifest,
                    "token": token,
                }))
                continue

            # Delete for everyone — also purge from offline queue
            if msg_type == "delete_message":
                recipient_id = data.get("recipient_id")
                recipient_id = recipient_id.strip().upper() if recipient_id else None
                msg_uuid = data.get("message_uuid", "")
                if recipient_id and msg_uuid and recipient_id in offline_queue:
                    offline_queue[recipient_id] = [
                        entry for entry in offline_queue[recipient_id]
                        if msg_uuid not in entry[1]
                    ]
                if recipient_id:
                    await _deliver(recipient_id, raw, "delete_message")
                continue

            # Route all other messages (chat, ack, file_chunk, pair_request, ...)
            recipient_id = data.get("recipient_id")
            if recipient_id:
                recipient_id = str(recipient_id).strip().upper()
                await _deliver(recipient_id, raw, msg_type)

    except WebSocketDisconnect:
        pass
    except Exception as e:
        logger.debug("Connection error: %s", e)
    finally:
        if current_user_id and active_clients.get(current_user_id) is websocket:
            active_clients.pop(current_user_id, None)
            logger.info("Disconnected: %s (active=%d)",
                        _uid(current_user_id), len(active_clients))


# ── Endpoints ────────────────────────────────────────────────────────────────

@app.websocket("/ws/{user_id}")
async def ws_with_user_id(websocket: WebSocket, user_id: str):
    """Path-based connection — user_id is a hint; still requires signature."""
    await _handle_ws(websocket, user_id_from_path=user_id)


@app.websocket("/ws")
async def ws_root(websocket: WebSocket):
    """Root WebSocket — registers via signed {type: register, ...} message."""
    await _handle_ws(websocket)


@app.websocket("/")
async def ws_plain(websocket: WebSocket):
    """Plain root WebSocket for plain ws://host:port relay mode."""
    await _handle_ws(websocket)


@app.get("/health")
async def health():
    return JSONResponse({
        "status": "ok",
        "active_users": len(active_clients),
        "server": "WASL Relay v2 (Zero-Knowledge)"
    })


@app.get("/")
async def root():
    return JSONResponse({"wasl": "relay", "status": "running"})


@app.get("/update/apk")
async def update_apk(token: str = ""):
    """Closed-channel APK download.

    Requires a single-use token minted over an authenticated WS session via
    `update_check` — the URL alone is dead: unknown/expired/consumed tokens
    get a 404, so the app file can never be fetched by link-sharing.
    """
    exp = _download_tokens.pop(token, None)   # single-use: consume it
    if exp is None or exp < time.time():
        raise HTTPException(status_code=404)
    path = os.path.join(UPDATE_DIR, "wasl-release.apk")
    if not os.path.isfile(path):
        raise HTTPException(status_code=404)
    logger.info("Serving update APK to an authenticated session token")
    return FileResponse(
        path, media_type="application/vnd.android.package-archive")


@app.put("/admin/update/{name}")
async def admin_update_upload(name: str, request: Request):
    """Operator-only upload of release files (version.json / APK).

    Guarded by the ADMIN_TOKEN env secret — returns 404 (not 403) so the
    endpoint's existence isn't advertised to anyone probing the service.
    """
    if not ADMIN_TOKEN or request.headers.get("x-admin-token") != ADMIN_TOKEN:
        raise HTTPException(status_code=404)
    if name not in ("version.json", "wasl-release.apk"):
        raise HTTPException(status_code=404)
    try:
        os.makedirs(UPDATE_DIR, exist_ok=True)
        dest = os.path.join(UPDATE_DIR, name)
        size = 0
        with open(dest, "wb") as f:
            async for chunk in request.stream():
                size += len(chunk)
                if size > UPDATE_MAX_BYTES:
                    f.close()
                    try:
                        os.remove(dest)
                    except OSError:
                        pass
                    raise HTTPException(status_code=413)
                f.write(chunk)
    except HTTPException:
        raise
    except Exception as e:
        # Admin-only endpoint — echoing the failure reason is safe here and
        # makes ops debugging (e.g. unmounted disk) possible without logs.
        logger.exception("Update upload failed for %s", name)
        raise HTTPException(status_code=500, detail=f"upload_failed: {e}")
    logger.info("Update asset uploaded: %s (%d bytes)", name, size)
    return JSONResponse({"ok": True, "bytes": size})


# ── Entry Point ───────────────────────────────────────────────────────────────

if __name__ == "__main__":
    import uvicorn
    port = int(os.environ.get("PORT", 8765))
    logger.info("=" * 50)
    logger.info("  WASL Relay Server v2 — Zero-Knowledge Mode")
    logger.info(f"  Listening on port {port}")
    logger.info("  No disk storage | Ephemeral RAM forwarding only")
    logger.info("=" * 50)
    uvicorn.run(app, host="0.0.0.0", port=port)
