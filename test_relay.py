#!/usr/bin/env python3
"""WASL relay smoke test — checks deployed version & offline queue flow."""
import asyncio, base64, json
import websockets
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey
from cryptography.hazmat.primitives.serialization import Encoding, PublicFormat

# Persistent identity keys per test user (like a real device)
_keys = {}
def user_key(uid):
    if uid not in _keys:
        _keys[uid] = Ed25519PrivateKey.generate()
    return _keys[uid]

def make_register(user_id, nonce):
    priv = user_key(user_id)
    pub = priv.public_key().public_bytes(Encoding.Raw, PublicFormat.Raw)
    sig = priv.sign(f"wasl-register|{user_id}|{nonce}".encode())
    return json.dumps({
        "type": "register", "user_id": user_id,
        "public_key": base64.b64encode(pub).decode(),
        "nonce": nonce, "signature": base64.b64encode(sig).decode(),
    })

async def recv_timeout(ws, t=8):
    try:
        return json.loads(await asyncio.wait_for(ws.recv(), timeout=t))
    except asyncio.TimeoutError:
        return None

async def register_user(url, user_id):
    """Connect, read challenge, send signed register, expect 'registered'."""
    ws = await websockets.connect(url)
    chal = await recv_timeout(ws)
    if not chal or chal.get("type") != "challenge":
        return ws, None
    await ws.send(make_register(user_id, chal["nonce"]))
    ack = await recv_timeout(ws, 5)
    ok = ack and ack.get("type") == "registered"
    return ws, ok

async def test_local(base):
    print(f"\n=== LOCAL TEST: {base} ===")
    ws_a = await websockets.connect(base)
    chal = await recv_timeout(ws_a)
    print("1. challenge on connect:", chal)
    if not chal:
        print("   -> OLD SERVER (no auth)")
        return

    await ws_a.send(json.dumps({"type": "register", "user_id": "WASL-BADGUY"}))
    resp = await recv_timeout(ws_a, 4)
    print("2. unsigned register ->", resp, "(expect register_error)")
    await ws_a.close()

    ws_a, ok_a = await register_user(base, "WASL-AAAA")
    print("3. A authenticated:", ok_a)
    ws_b, ok_b = await register_user(base, "WASL-BBBB")
    print("   B authenticated:", ok_b)

    # A goes offline, B sends a message to A
    await ws_a.close()
    await asyncio.sleep(0.4)
    msg = {"type": "chat_message", "message_uuid": "TEST-UUID-1",
           "sender_id": "WASL-BBBB", "recipient_id": "WASL-AAAA",
           "ciphertext": "abc", "nonce": "n", "mac": "m"}
    await ws_b.send(json.dumps(msg))
    print("4. B sent chat_message to offline A (should buffer)")

    # A reconnects with SAME key -> 'registered' then buffered message
    ws_a2, ok_a2 = await register_user(base, "WASL-AAAA")
    print("5. A re-authenticated:", ok_a2)
    delivered = False
    for _ in range(3):
        m = await recv_timeout(ws_a2, 4)
        if m is None:
            break
        if m.get("type") == "chat_message":
            delivered = m.get("message_uuid") == "TEST-UUID-1"
            print("   A received buffered message:", m.get("message_uuid"))
            break
    print("   OFFLINE DELIVERY:", "PASS" if delivered else "FAIL")

    # Impersonation attempt: different key, same user_id -> key_mismatch
    _keys.pop("WASL-AAAA")
    ws_x = await websockets.connect(base)
    chal_x = await recv_timeout(ws_x)
    if chal_x:
        await ws_x.send(make_register("WASL-AAAA", chal_x["nonce"]))
        print("6. impersonation ->", await recv_timeout(ws_x, 4),
              "(expect key_mismatch)")

async def test_render():
    url = "wss://wasl-rela.onrender.com/ws"
    print(f"\n=== RENDER CHECK: {url} ===")
    try:
        ws = await websockets.connect(url, open_timeout=15)
        msg = await recv_timeout(ws, 10)
        print("first frame:", msg)
        if msg and msg.get("type") == "challenge":
            print("-> NEW server DEPLOYED on Render")
        else:
            print("-> OLD server still running (no challenge frame)")
        await ws.close()
    except Exception as e:
        print("render unreachable:", e)

async def main():
    await test_local("ws://127.0.0.1:8765")
    await test_render()

if __name__ == "__main__":
    asyncio.run(main())
