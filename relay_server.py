#!/usr/bin/env python3
"""
WASL Secure Relay Server — Render-Compatible Version
Privacy-by-Design | Zero-Knowledge | In-Memory Only

Supports TWO connection modes:
  1. Path-based: wss://host/ws/{user_id}   (auto-registers on connect)
  2. Message-based: wss://host/ws/anonymous + {type: register, user_id: ...}

Render sets the PORT env variable automatically.
"""

import asyncio
import collections
import json
import logging
import os
from typing import Dict, List

from fastapi import FastAPI, WebSocket, WebSocketDisconnect
from fastapi.responses import JSONResponse

logging.basicConfig(
    level=logging.INFO,
    format="[%(asctime)s] [WASL] %(message)s",
    datefmt="%Y-%m-%d %H:%M:%S",
)
logger = logging.getLogger("wasl_relay")

app = FastAPI(title="WASL E2EE Relay", docs_url=None, redoc_url=None)

# user_id -> WebSocket
active_clients: Dict[str, WebSocket] = {}

# Ephemeral offline queue: user_id -> list of raw JSON strings (RAM only)
offline_queue: Dict[str, List[str]] = collections.defaultdict(list)

MAX_QUEUE = 300


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
    if len(q) < MAX_QUEUE:
        q.append(payload)
        logger.info(f"Buffered [{msg_type}] for offline user {recipient_id} (queue={len(q)})")
    else:
        logger.warning(f"Queue full for {recipient_id}, dropping [{msg_type}]")
    return False


async def _flush_queue(user_id: str, ws: WebSocket):
    """Flush buffered messages when user comes online."""
    pending = offline_queue.pop(user_id, [])
    if pending:
        logger.info(f"Flushing {len(pending)} queued message(s) to {user_id}")
        for raw in pending:
            try:
                await ws.send_text(raw)
            except Exception:
                break


async def _handle_ws(websocket: WebSocket, user_id_from_path: str = ""):
    """Core WebSocket handler shared by both path-based and root endpoints."""
    await websocket.accept()
    current_user_id: str = user_id_from_path

    # Auto-register if user_id is provided in the path
    if current_user_id and current_user_id != "anonymous":
        active_clients[current_user_id] = websocket
        logger.info(f"Auto-registered from path: {current_user_id} (active={len(active_clients)})")
        await _flush_queue(current_user_id, websocket)

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

            # Registration via message (legacy mode for plain relay ws://host:port)
            if msg_type == "register":
                uid = data.get("user_id", "")
                if uid:
                    # Remove old registration if moved
                    if current_user_id and current_user_id in active_clients:
                        if active_clients[current_user_id] is websocket:
                            active_clients.pop(current_user_id, None)

                    current_user_id = uid
                    active_clients[uid] = websocket
                    logger.info(f"Registered via message: {uid} (active={len(active_clients)})")
                    await _flush_queue(uid, websocket)
                continue

            # Delete for everyone — also purge from offline queue
            if msg_type == "delete_message":
                recipient_id = data.get("recipient_id")
                msg_uuid = data.get("message_uuid", "")
                if recipient_id and msg_uuid and recipient_id in offline_queue:
                    offline_queue[recipient_id] = [
                        m for m in offline_queue[recipient_id] if msg_uuid not in m
                    ]
                if recipient_id:
                    await _deliver(recipient_id, raw, "delete_message")
                continue

            # Route all other messages (chat, ack, file_chunk, pair_request, etc.)
            recipient_id = data.get("recipient_id")
            if recipient_id:
                await _deliver(recipient_id, raw, msg_type)

    except WebSocketDisconnect:
        pass
    except Exception as e:
        logger.debug(f"Connection error: {e}")
    finally:
        if current_user_id and active_clients.get(current_user_id) is websocket:
            active_clients.pop(current_user_id, None)
            logger.info(f"Disconnected: {current_user_id} (active={len(active_clients)})")


# ── Endpoints ────────────────────────────────────────────────────────────────

@app.websocket("/ws/{user_id}")
async def ws_with_user_id(websocket: WebSocket, user_id: str):
    """Path-based connection: wss://host/ws/{user_id}"""
    await _handle_ws(websocket, user_id_from_path=user_id)


@app.websocket("/ws")
async def ws_root(websocket: WebSocket):
    """Root WebSocket — registers via {type: register, user_id: ...} message."""
    await _handle_ws(websocket, user_id_from_path="")


@app.websocket("/")
async def ws_plain(websocket: WebSocket):
    """Plain root WebSocket for plain ws://host:port relay mode."""
    await _handle_ws(websocket, user_id_from_path="")


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
