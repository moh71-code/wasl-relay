import 'dart:convert';
import 'dart:math';
import 'package:cryptography/cryptography.dart';
import 'package:flutter/foundation.dart';
import '../storage/storage_service.dart';
import '../network/websocket_service.dart';

/// Coordinates the device-side identity and pairing protocol.
/// Every signed payload is built by [canonicalPayload] so signing and
/// verification cannot silently disagree about fields.
class PairingService {
  static final PairingService _instance = PairingService._internal();
  factory PairingService() => _instance;
  PairingService._internal();

  final Ed25519 _ed = Ed25519();
  final X25519 _x = X25519();
  final StorageService _storage = StorageService();

  static Map<String, dynamic> canonicalPayload({
    required String type,
    required String senderId,
    required String recipientId,
    required String x25519,
    required String ed25519,
    String? requestId,
    String? challenge,
    int? expiresAt,
  }) => <String, dynamic>{
        'type': type,
        'sender_id': senderId,
        'recipient_id': recipientId,
        'x25519': x25519,
        'ed25519': ed25519,
        if (requestId != null) 'request_id': requestId,
        if (challenge != null) 'challenge': challenge,
        if (expiresAt != null) 'expires_at': expiresAt,
      };

  Future<void> ensureIdentityKeys(String userId) async {
    final existingEd = await _storage.getEdPrivateKey(userId);
    final existingX = await _storage.getXPrivateKey(userId);
    final existingEdPub = await _storage.getEdPublicKey(userId);
    final existingXPub = await _storage.getXPublicKey(userId);
    if (existingEd != null && existingX != null &&
        existingEdPub != null && existingXPub != null) {
      return;
    }
    if (existingEd != null || existingX != null ||
        existingEdPub != null || existingXPub != null) {
      throw StateError('Incomplete identity key set for $userId');
    }

    final edPair = await _ed.newKeyPair();
    final xPair = await _x.newKeyPair();
    final edPub = await edPair.extractPublicKey();
    final xPub = await xPair.extractPublicKey();
    await _storage.saveEdPrivateKey(userId,
        base64Encode(await edPair.extractPrivateKeyBytes()));
    await _storage.saveXPrivateKey(userId,
        base64Encode(await xPair.extractPrivateKeyBytes()));
    await _storage.saveEdPublicKey(userId, base64Encode(edPub.bytes));
    await _storage.saveXPublicKey(userId, base64Encode(xPub.bytes));
  }

  Future<Map<String, String>> getLocalPublicKeys(String userId) async {
    final edPub = await _storage.getEdPublicKey(userId);
    final xPub = await _storage.getXPublicKey(userId);
    if (edPub == null || xPub == null) {
      throw StateError('Identity public keys are not initialized for $userId');
    }
    return {'ed25519': edPub, 'x25519': xPub};
  }

  Future<List<int>> sign(String userId, List<int> message) async {
    final b64 = await _storage.getEdPrivateKey(userId);
    if (b64 == null) throw StateError('No Ed25519 private key for $userId');
    final keyPair = await _ed.newKeyPairFromSeed(base64.decode(b64));
    return (await _ed.sign(message, keyPair: keyPair)).bytes;
  }

  Future<bool> verify(List<int> message, List<int> signatureBytes,
      List<int> pubBytes) async {
    if (pubBytes.length != 32 || signatureBytes.length != 64) return false;
    final pub = SimplePublicKey(pubBytes, type: KeyPairType.ed25519);
    return _ed.verify(message,
        signature: Signature(signatureBytes, publicKey: pub));
  }

  Future<List<int>> deriveAndStoreSessionKey({
    required String myUserId,
    required String peerId,
    required List<int> peerXPublicBytes,
  }) async {
    if (peerXPublicBytes.length != 32) throw FormatException('Invalid X25519 public key');
    final myXb64 = await _storage.getXPrivateKey(myUserId);
    if (myXb64 == null) throw StateError('No X25519 private key for $myUserId');
    final myPair = await _x.newKeyPairFromSeed(base64.decode(myXb64));
    final sharedSecret = await _x.sharedSecretKey(
      keyPair: myPair,
      remotePublicKey: SimplePublicKey(peerXPublicBytes, type: KeyPairType.x25519),
    );
    final hkdf = Hkdf(hmac: Hmac.sha256(), outputLength: 32);
    final sessionKey = await hkdf.deriveKey(
      secretKey: sharedSecret,
      info: utf8.encode('wasl-session-v1:$myUserId:$peerId'),
    );
    final keyBytes = await sessionKey.extractBytes();
    await _storage.saveSessionKey(myUserId, peerId, base64Encode(keyBytes));
    return keyBytes;
  }

  Future<void> sendPairRequest({required String myId, required String targetId}) async {
    await ensureIdentityKeys(myId);
    final pubs = await getLocalPublicKeys(myId);
    final requestId = DateTime.now().microsecondsSinceEpoch.toString();
    final expiresAt = DateTime.now().add(const Duration(minutes: 5)).millisecondsSinceEpoch;
    final payload = canonicalPayload(
      type: 'pair_request', senderId: myId, recipientId: targetId,
      x25519: pubs['x25519']!, ed25519: pubs['ed25519']!,
      requestId: requestId, challenge: base64UrlEncode(List<int>.generate(32, (_) => Random.secure().nextInt(256))),
      expiresAt: expiresAt,
    );
    final signature = await sign(myId, utf8.encode(jsonEncode(payload)));
    WebSocketService().sendData({...payload, 'signature': base64Encode(signature)});
  }

  Future<bool> handlePairAccept(Map<String, dynamic> data,
      {String? expectedRecipientId}) async {
    try {
      if (data['type'] != 'pair_accept') return false;
      final sender = data['sender_id'] as String;
      final recipient = data['recipient_id'] as String;
      if (expectedRecipientId != null && recipient != expectedRecipientId) return false;
      final edPubB64 = data['ed25519'] as String;
      final xPubB64 = data['x25519'] as String;
      final sigB64 = data['signature'] as String?;
      if (sigB64 == null) return false;
      final payload = canonicalPayload(
        type: 'pair_accept', senderId: sender, recipientId: recipient,
        x25519: xPubB64, ed25519: edPubB64,
        requestId: data['request_id'] as String?,
        challenge: data['challenge'] as String?,
        expiresAt: data['expires_at'] as int?,
      );
      final verified = await verify(utf8.encode(jsonEncode(payload)),
          base64.decode(sigB64), base64.decode(edPubB64));
      if (!verified) return false;
      await deriveAndStoreSessionKey(
        myUserId: recipient, peerId: sender,
        peerXPublicBytes: base64.decode(xPubB64));
      return true;
    } catch (e) {
      if (kDebugMode) debugPrint('Pair accept handling failed: $e');
      return false;
    }
  }

  /// Generate cryptographically secure anonymous User ID (WASL-XXXXXXXXXXXX)
  static String generateSecureUserId() {
    final rand = Random.secure();
    final bytes = List<int>.generate(6, (_) => rand.nextInt(256));
    final hex = bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join('').toUpperCase();
    return 'WASL-$hex';
  }

  /// Sign a control message (such as delete_message or read_ack)
  Future<String> signControlPayload(String myId, Map<String, dynamic> payload) async {
    final bytes = utf8.encode(jsonEncode(payload));
    final sig = await sign(myId, bytes);
    return base64Encode(sig);
  }

  /// Verify a control message from a peer
  Future<bool> verifyControlPayload(
      Map<String, dynamic> payload, String signatureB64, String peerId) async {
    final peerEd = await _storage.getEdPublicKey(peerId);
    if (peerEd == null) return false;
    final bytes = utf8.encode(jsonEncode(payload));
    return verify(bytes, base64.decode(signatureB64), base64.decode(peerEd));
  }
}
