import 'package:flutter_secure_storage/flutter_secure_storage.dart';

class StorageService {
  static final StorageService _instance = StorageService._internal();
  factory StorageService() => _instance;
  StorageService._internal();

  final _storage = const FlutterSecureStorage(
    aOptions: AndroidOptions(),
    iOptions: IOSOptions(accessibility: KeychainAccessibility.first_unlock),
  );

  static String _norm(String id) => id.trim().toUpperCase();

  // User identity
  Future<void> saveUserId(String userId) async {
    await _storage.write(key: 'user_id', value: _norm(userId));
  }

  Future<String?> getUserId() async {
    final val = await _storage.read(key: 'user_id');
    return val != null ? _norm(val) : null;
  }

  // Human-readable display name shown to paired peers
  Future<void> saveDisplayName(String name) async {
    final trimmed = name.trim();
    if (trimmed.isEmpty) return;
    await _storage.write(key: 'display_name', value: trimmed);
  }

  Future<String?> getDisplayName() async {
    final val = await _storage.read(key: 'display_name');
    if (val == null) return null;
    final trimmed = val.trim();
    return trimmed.isEmpty ? null : trimmed;
  }

  // Ed25519 identity keys (Signing & Verification)
  Future<void> saveEdPrivateKey(String userId, String b64) async {
    await _storage.write(key: 'ed_priv_${_norm(userId)}', value: b64);
  }

  Future<String?> getEdPrivateKey(String userId) async {
    return await _storage.read(key: 'ed_priv_${_norm(userId)}');
  }

  Future<void> saveEdPublicKey(String userId, String b64) async {
    await _storage.write(key: 'ed_pub_${_norm(userId)}', value: b64);
  }

  Future<String?> getEdPublicKey(String userId) async {
    return await _storage.read(key: 'ed_pub_${_norm(userId)}');
  }

  // X25519 key exchange keys (Diffie-Hellman)
  Future<void> saveXPrivateKey(String userId, String b64) async {
    await _storage.write(key: 'x_priv_${_norm(userId)}', value: b64);
  }

  Future<String?> getXPrivateKey(String userId) async {
    return await _storage.read(key: 'x_priv_${_norm(userId)}');
  }

  Future<void> saveXPublicKey(String userId, String b64) async {
    await _storage.write(key: 'x_pub_${_norm(userId)}', value: b64);
  }

  Future<String?> getXPublicKey(String userId) async {
    return await _storage.read(key: 'x_pub_${_norm(userId)}');
  }

  // Session keys derived per contact
  Future<void> saveSessionKey(
      String myUserId, String peerId, String b64) async {
    await _storage.write(key: 'session_${_norm(myUserId)}_${_norm(peerId)}', value: b64);
  }

  Future<String?> getSessionKey(String myUserId, String peerId) async {
    return await _storage.read(key: 'session_${_norm(myUserId)}_${_norm(peerId)}');
  }

  Future<void> deleteSessionKey(String myUserId, String peerId) async {
    await _storage.delete(key: 'session_${_norm(myUserId)}_${_norm(peerId)}');
  }

  // Shared AES-256 group keys (distributed per-member over pairwise channels)
  Future<void> saveGroupKey(String groupId, String b64) async {
    await _storage.write(key: 'group_key_${_norm(groupId)}', value: b64);
  }

  Future<String?> getGroupKey(String groupId) async {
    return await _storage.read(key: 'group_key_${_norm(groupId)}');
  }

  Future<void> deleteGroupKey(String groupId) async {
    await _storage.delete(key: 'group_key_${_norm(groupId)}');
  }

  // Relay server settings
  Future<void> saveRelayConfig({
    required String host,
    required int port,
    required bool useWss,
  }) async {
    await _storage.write(key: 'relay_host', value: host);
    await _storage.write(key: 'relay_port', value: port.toString());
    await _storage.write(key: 'relay_wss', value: useWss ? 'true' : 'false');
  }

  Future<Map<String, dynamic>> getRelayConfig() async {
    final host = await _storage.read(key: 'relay_host') ?? 'wasl-rela.onrender.com';
    final portStr = await _storage.read(key: 'relay_port') ?? '443';
    final wssStr = await _storage.read(key: 'relay_wss') ?? 'true';
    return {
      'host': host,
      'port': int.tryParse(portStr) ?? 443,
      'useWss': wssStr == 'true',
    };
  }

  // Privacy preferences
  Future<void> savePrivacySettings({
    required bool sendReadReceipts,
    required bool autoDownloadMedia,
    int? defaultEphemeralTtl,
    String? defaultEphemeralTrigger,
  }) async {
    await _storage.write(
        key: 'pref_read_receipts', value: sendReadReceipts ? 'true' : 'false');
    await _storage.write(
        key: 'pref_auto_download', value: autoDownloadMedia ? 'true' : 'false');
    if (defaultEphemeralTtl != null) {
      await _storage.write(
          key: 'pref_ephemeral_ttl', value: defaultEphemeralTtl.toString());
    } else {
      await _storage.delete(key: 'pref_ephemeral_ttl');
    }
    if (defaultEphemeralTrigger != null) {
      await _storage.write(
          key: 'pref_ephemeral_trigger', value: defaultEphemeralTrigger);
    }
  }

  Future<Map<String, dynamic>> getPrivacySettings() async {
    final readReceipts =
        (await _storage.read(key: 'pref_read_receipts')) != 'false';
    final autoDownload =
        (await _storage.read(key: 'pref_auto_download')) != 'false';
    final ttlStr = await _storage.read(key: 'pref_ephemeral_ttl');
    final trigger =
        await _storage.read(key: 'pref_ephemeral_trigger') ?? 'send';

    return {
      'sendReadReceipts': readReceipts,
      'autoDownloadMedia': autoDownload,
      'defaultEphemeralTtl': ttlStr != null ? int.tryParse(ttlStr) : null,
      'defaultEphemeralTrigger': trigger,
    };
  }

  /// Secure Zeroize: Irreversibly wipe all cryptographic keys and credentials
  Future<void> wipeAllSecureKeys() async {
    await _storage.deleteAll();
  }

  // Update-check throttle timestamp (ms since epoch).
  Future<int> getLastUpdateCheck() async =>
      int.tryParse(await _storage.read(key: 'last_update_check') ?? '0') ?? 0;

  Future<void> setLastUpdateCheck(int ms) async =>
      _storage.write(key: 'last_update_check', value: ms.toString());

  // App-lock PIN (stored as salted SHA-256, never the raw PIN)
  static const String _pinKey = 'app_pin_hash_v1';

  Future<void> savePinHash(String saltedHash) async {
    await _storage.write(key: _pinKey, value: saltedHash);
  }

  Future<String?> getPinHash() async {
    return await _storage.read(key: _pinKey);
  }

  Future<void> clearPin() async {
    await _storage.delete(key: _pinKey);
  }
}
