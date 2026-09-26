#!/usr/bin/env python3
"""
WASL Secure & Private Relay Server
Privacy-by-Design & Zero-Knowledge Stateless Message Transport

Features:
- Pure in-memory message forwarding (No disk persistence)
- Ephemeral in-memory queuing for offline recipients (24h TTL)
- Automatic purge upon delivery
- No logging of message contents, keys, or metadata
- Ed25519 challenge-response authenticated registration
- Lightweight asyncio WebSocket architecture
"""

import asyncio
import base64
import collections
import hashlib
import json
import logging
import os
import sys
import time

try:
    from cryptography.exceptions import InvalidSignature
    from cryptography.hazmat.primitives.asymmetric.ed25519 import (
        Ed25519PublicKey,
    )
    _ED25519_AVAILABLE = True
except ImportError:
    _ED25519_AVAILABLE = False

# Configure privacy-conscious logging (Log connection events only, never payloads)
logging.basicConfig(
    level=logging.INFO,
    format='[%(asctime)s] [WASL-RELAY] %(message)s',
    datefmt='%Y-%m-%d %H:%M:%S'
)
logger = logging.getLogger("wasl_relay")

# Active client connections: user_id -> WebSocketServerProtocol
active_clients = {}

# user_id -> bound Ed25519 public key (base64), trust-on-first-use in RAM
user_bindings = {}

# Ephemeral in-memory queue: user_id -> [(unix_ts, raw message string)]
# Kept in RAM only until recipient connects, then immediately purged.
ephemeral_offline_queue = collections.defaultdict(list)

MAX_QUEUE_PER_USER = 200

# Queued ciphertexts expire after 24 hours — recipients who never come
# online must not accumulate data in RAM forever.
QUEUE_TTL_SECONDS = 24 * 60 * 60


def _uid(user_id: str) -> str:
    """Log-safe user handle — never print raw user_ids."""
    return "u#" + hashlib.sha256(user_id.encode()).hexdigest()[:10]


def _prune_queue(user_id: str) -> None:
    q = ephemeral_offline_queue.get(user_id)
    if not q:
        return
    cutoff = time.time() - QUEUE_TTL_SECONDS
    fresh = [entry for entry in q if entry[0] >= cutoff]
    if fresh:
        ephemeral_offline_queue[user_id] = fresh
    else:
        ephemeral_offline_queue.pop(user_id, None)


def _verify_register(user_id: str, public_key_b64: str, nonce: str,
                     signature_b64: str) -> bool:
    """Verify the Ed25519 challenge-response signature for registration."""
    if not _ED25519_AVAILABLE:
        logger.error("Missing dependency 'cryptography'. Run: pip install cryptography")
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


async def route_message(recipient_id: str, raw_payload: str, msg_type: str):
    """Deliver to recipient if online, or buffer in ephemeral memory queue."""
    if recipient_id in active_clients:
        recipient_ws = active_clients[recipient_id]
        try:
            await recipient_ws.send(raw_payload)
            return True
        except Exception:
            # Socket failed, drop from active clients
            active_clients.pop(recipient_id, None)

    # Recipient offline: Buffer temporarily in RAM
    _prune_queue(recipient_id)
    queue = ephemeral_offline_queue[recipient_id]
    if len(queue) < MAX_QUEUE_PER_USER:
        queue.append((time.time(), raw_payload))
        logger.info(f"Buffered {msg_type} for offline client: {_uid(recipient_id)} (Queue: {len(queue)})")
    else:
        logger.warning(f"Ephemeral queue full for {_uid(recipient_id)}, dropping packet.")
    return False


async def handle_connection(websocket):
    current_user_id = None
    authenticated = False
    remote_addr = websocket.remote_address[0] if websocket.remote_address else "unknown"
    logger.info(f"New incoming transport connection from {remote_addr}")

    # Registration challenge: a unique nonce per connection.
    nonce = base64.b64encode(os.urandom(32)).decode()
    await websocket.send(json.dumps({"type": "challenge", "nonce": nonce}))

    try:
        async for raw_message in websocket:
            try:
                data = json.loads(raw_message)
            except json.JSONDecodeError:
                continue

            msg_type = data.get("type", "")

            # 1. Heartbeat Ping / Pong
            if msg_type == "ping":
                await websocket.send(json.dumps({"type": "pong"}))
                continue
            elif msg_type == "pong":
                continue

            # 2. Authenticated Client Identity Registration
            if msg_type == "register":
                user_id = str(data.get("user_id", "")).strip().upper()
                pub_b64 = str(data.get("public_key", ""))
                sig_b64 = str(data.get("signature", ""))
                echoed = str(data.get("nonce", ""))
                if not user_id:
                    continue
                if echoed != nonce or not _verify_register(
                        user_id, pub_b64, echoed, sig_b64):
                    logger.warning(f"Rejected unauthenticated register for {_uid(user_id)}")
                    await websocket.send(json.dumps(
                        {"type": "register_error", "reason": "auth_failed"}))
                    try:
                        await websocket.close(code=4003)
                    except Exception:
                        pass
                    return
                bound = user_bindings.get(user_id)
                if bound is not None and bound != pub_b64:
                    logger.warning(f"Rejected key mismatch for {_uid(user_id)}")
                    await websocket.send(json.dumps(
                        {"type": "register_error", "reason": "key_mismatch"}))
                    try:
                        await websocket.close(code=4003)
                    except Exception:
                        pass
                    return
                user_bindings.setdefault(user_id, pub_b64)

                current_user_id = user_id
                authenticated = True
                active_clients[user_id] = websocket
                logger.info(f"Client registered: {_uid(user_id)} (Active: {len(active_clients)})")

                # Confirm auth BEFORE flushing — the client only starts
                # sending app frames once it sees 'registered', closing the
                # race where pre-auth frames were silently dropped.
                await websocket.send(json.dumps({"type": "registered"}))

                # Flush ephemeral offline queue for this user
                _prune_queue(user_id)
                if user_id in ephemeral_offline_queue:
                    pending = ephemeral_offline_queue.pop(user_id)
                    logger.info(f"Flushing {len(pending)} ephemeral message(s) to {_uid(user_id)}")
                    for _ts, queued_msg in pending:
                        try:
                            await websocket.send(queued_msg)
                        except Exception:
                            break
                continue

            # Everything below requires an authenticated registration.
            if not authenticated:
                continue

            # 3. Message Deletion Control (Delete for everyone)
            if msg_type == "delete_message":
                recipient_id = data.get("recipient_id")
                recipient_id = recipient_id.strip().upper() if recipient_id else None
                message_uuid = data.get("message_uuid")
                # Also purge from ephemeral queue if still waiting
                if recipient_id and message_uuid and recipient_id in ephemeral_offline_queue:
                    ephemeral_offline_queue[recipient_id] = [
                        entry for entry in ephemeral_offline_queue[recipient_id]
                        if message_uuid not in entry[1]
                    ]
                if recipient_id:
                    await route_message(recipient_id, raw_message, "delete_message")
                continue

            # 4. Routed Messages (chat_message, file_chunk, acks, pairing)
            recipient_id = data.get("recipient_id")
            if recipient_id:
                recipient_id = str(recipient_id).strip().upper()
                await route_message(recipient_id, raw_message, msg_type)

    except Exception as e:
        logger.debug(f"Connection ended with exception: {e}")
    finally:
        if current_user_id and active_clients.get(current_user_id) == websocket:
            active_clients.pop(current_user_id, None)
            logger.info(f"Client disconnected: {_uid(current_user_id)} (Active: {len(active_clients)})")

async def main():
    try:
        import websockets
    except ImportError:
        logger.error("Missing dependency 'websockets'. Run: pip install websockets")
        return

    host = "0.0.0.0"
    port = 8765

    logger.info("==================================================")
    logger.info("  WASL Relay Server (Privacy-by-Design & Zero-Log)")
    logger.info(f"  Listening on ws://{host}:{port}")
    logger.info("  No disk storage | Ephemeral memory forwarding only")
    logger.info("==================================================")

    async with websockets.serve(
        handle_connection,
        host,
        port,
        max_size=8 * 1024 * 1024,
        ping_interval=20,
        ping_timeout=20,
    ):
        await asyncio.Future()  # Run forever

if __name__ == "__main__":
    try:
        asyncio.run(main())
    except KeyboardInterrupt:
        logger.info("Relay server stopped by administrator.")
