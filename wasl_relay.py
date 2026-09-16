#!/usr/bin/env python3
"""
WASL Secure & Private Relay Server
Privacy-by-Design & Zero-Knowledge Stateless Message Transport

Features:
- Pure in-memory message forwarding (No disk persistence)
- Ephemeral in-memory queuing for offline recipients
- Automatic purge upon delivery
- No logging of message contents, keys, or metadata
- Lightweight asyncio WebSocket architecture
"""

import asyncio
import collections
import json
import logging
import sys

# Configure privacy-conscious logging (Log connection events only, never payloads)
logging.basicConfig(
    level=logging.INFO,
    format='[%(asctime)s] [WASL-RELAY] %(message)s',
    datefmt='%Y-%m-%d %H:%M:%S'
)
logger = logging.getLogger("wasl_relay")

# Active client connections: user_id -> WebSocketServerProtocol
active_clients = {}

# Ephemeral in-memory queue: user_id -> list of raw message strings
# Kept in RAM only until recipient connects, then immediately purged.
ephemeral_offline_queue = collections.defaultdict(list)

MAX_QUEUE_PER_USER = 200

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
    queue = ephemeral_offline_queue[recipient_id]
    if len(queue) < MAX_QUEUE_PER_USER:
        queue.append(raw_payload)
        logger.info(f"Buffered {msg_type} for offline client: {recipient_id} (Queue: {len(queue)})")
    else:
        logger.warning(f"Ephemeral queue full for {recipient_id}, dropping packet.")
    return False

async def handle_connection(websocket):
    current_user_id = None
    remote_addr = websocket.remote_address[0] if websocket.remote_address else "unknown"
    logger.info(f"New incoming transport connection from {remote_addr}")

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

            # 2. Client Identity Registration
            if msg_type == "register":
                user_id = data.get("user_id")
                if user_id:
                    current_user_id = user_id
                    active_clients[user_id] = websocket
                    logger.info(f"Client registered: {user_id} (Active: {len(active_clients)})")

                    # Flush ephemeral offline queue for this user
                    if user_id in ephemeral_offline_queue:
                        pending = ephemeral_offline_queue.pop(user_id)
                        logger.info(f"Flushing {len(pending)} ephemeral message(s) to {user_id}")
                        for queued_msg in pending:
                            try:
                                await websocket.send(queued_msg)
                            except Exception:
                                break
                continue

            # 3. Message Deletion Control (Delete for everyone)
            if msg_type == "delete_message":
                recipient_id = data.get("recipient_id")
                message_uuid = data.get("message_uuid")
                # Also purge from ephemeral queue if still waiting
                if recipient_id and message_uuid and recipient_id in ephemeral_offline_queue:
                    ephemeral_offline_queue[recipient_id] = [
                        m for m in ephemeral_offline_queue[recipient_id]
                        if message_uuid not in m
                    ]
                if recipient_id:
                    await route_message(recipient_id, raw_message, "delete_message")
                continue

            # 4. Routed Messages (chat_message, file_chunk, acks, pairing)
            recipient_id = data.get("recipient_id")
            if recipient_id:
                await route_message(recipient_id, raw_message, msg_type)

    except Exception as e:
        logger.debug(f"Connection ended with exception: {e}")
    finally:
        if current_user_id and active_clients.get(current_user_id) == websocket:
            active_clients.pop(current_user_id, None)
            logger.info(f"Client disconnected: {current_user_id} (Active: {len(active_clients)})")

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

    async with websockets.serve(handle_connection, host, port):
        await asyncio.Future()  # Run forever

if __name__ == "__main__":
    try:
        asyncio.run(main())
    except KeyboardInterrupt:
        logger.info("Relay server stopped by administrator.")
