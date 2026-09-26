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
import time
from typing import Dict, List, Tuple

from fastapi import FastAPI, WebSocket, WebSocketDisconnect
from fastapi.responses import JSONResponse

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

app = FastAPI(title="WASL E2EE Relay", docs_url=None, redoc_url=None)

# user_id -> WebSocket (only AUTHENTICATED clients live here)
active_clients: Dict[str, WebSocket] = {}

# user_id -> bound Ed25519 public key (base64). Trust-on-first-use within the
# process lifetime: once bound, a user_id can only be claimed by the same key.
user_bindings: Dict[str, str] = {}

# Ephemeral offline queue: user_id -> [(unix_ts, raw JSON string)] (RAM only)
offline_queue: Dict[str, List[Tuple[float, str]]] = collections.defaultdict(list)

MAX_QUEUE = 300

# Queued ciphertexts expire after 24 hours — recipients who never come online
# must not accumulate data in RAM forever.
QUEUE_TTL_SECONDS = 24 * 60 * 60


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
    if len(q) < MAX_QUEUE:
        q.append((time.time(), payload))
        logger.info("Buffered [%s] for offline %s (queue=%d)",
                    msg_type, _uid(recipient_id), len(q))
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
