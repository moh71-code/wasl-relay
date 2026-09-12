import asyncio
import json
import logging
from typing import Dict
from fastapi import FastAPI, WebSocket, WebSocketDisconnect

logging.basicConfig(level=logging.INFO)
logger = logging.getLogger("WASL-Relay")

app = FastAPI(title="WASL E2EE Relay Server")

class ConnectionManager:
    def __init__(self):
        self.active_connections: Dict[str, WebSocket] = {}
        self.offline_queues: Dict[str, list] = {}

    async def connect(self, user_id: str, websocket: WebSocket):
        await websocket.accept()
        self.active_connections[user_id] = websocket
        logger.info(f"Connected: {user_id}")
        
        if user_id in self.offline_queues and self.offline_queues[user_id]:
            for msg in self.offline_queues[user_id]:
                await websocket.send_text(json.dumps(msg))
            self.offline_queues[user_id] = []

    def disconnect(self, user_id: str):
        if user_id in self.active_connections:
            del self.active_connections[user_id]
            logger.info(f"Disconnected: {user_id}")

    async def send_personal_message(self, message: dict, recipient_id: str) -> bool:
        if recipient_id in self.active_connections:
            await self.active_connections[recipient_id].send_text(json.dumps(message))
            return True
        else:
            if recipient_id not in self.offline_queues:
                self.offline_queues[recipient_id] = []
            self.offline_queues[recipient_id].append(message)
            return False

manager = ConnectionManager()

@app.websocket("/ws/{user_id}")
async def websocket_endpoint(websocket: WebSocket, user_id: str):
    await manager.connect(user_id, websocket)
    try:
        while True:
            data_str = await websocket.receive_text()
            data = json.loads(data_str)
            if data.get("type") == "ping":
                await websocket.send_text(json.dumps({"type": "pong"}))
                continue
            
            recipient_id = data.get("recipient_id")
            if recipient_id:
                delivered = await manager.send_personal_message(data, recipient_id)
                ack = {
                    "type": "ack",
                    "msg_id": data.get("msg_id"),
                    "status": "delivered_to_relay" if delivered else "queued_offline"
                }
                await websocket.send_text(json.dumps(ack))
    except WebSocketDisconnect:
        manager.disconnect(user_id)
    except Exception as e:
        logger.error(f"Error for {user_id}: {e}")
        manager.disconnect(user_id)

@app.get("/health")
async def health_check():
    return {"status": "ok", "active_users": len(manager.active_connections)}
