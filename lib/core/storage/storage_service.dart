import 'package:flutter_secure_storage/flutter_secure_storage.dart';

class StorageService {
  static final StorageService _instance = StorageService._internal();
  factory StorageService() => _instance;
  StorageService._internal();

  final _storage = const FlutterSecureStorage(
    aOptions: AndroidOptions(encryptedSharedPreferences: true),
    iOptions: IOSOptions(accessibility: KeychainAccessibility.first_unlock),
  );

  // User identity
  Future<void> saveUserId(String userId) async {
    await _storage.write(key: 'user_id', value: userId);
  }

  Future<String?> getUserId() async {
    return await _storage.read(key: 'user_id');
  }

  // Ed25519 identity keys (Signing & Verification)
  Future<void> saveEdPrivateKey(String userId, String b64) async {
    await _storage.write(key: 'ed_priv_$userId', value: b64);
  }

  Future<String?> getEdPrivateKey(String userId) async {
    return await _storage.read(key: 'ed_priv_$userId');
  }

  Future<void> saveEdPublicKey(String userId, String b64) async {
    await _storage.write(key: 'ed_pub_$userId', value: b64);
  }

  Future<String?> getEdPublicKey(String userId) async {
    return await _storage.read(key: 'ed_pub_$userId');
  }

  // X25519 key exchange keys (Diffie-Hellman)
  Future<void> saveXPrivateKey(String userId, String b64) async {
    await _storage.write(key: 'x_priv_$userId', value: b64);
  }

  Future<String?> getXPrivateKey(String userId) async {
    return await _storage.read(key: 'x_priv_$userId');
  }

  Future<void> saveXPublicKey(String userId, String b64) async {
    await _storage.write(key: 'x_pub_$userId', value: b64);
  }

  Future<String?> getXPublicKey(String userId) async {
    return await _storage.read(key: 'x_pub_$userId');
  }

  // Session keys derived per contact
  Future<void> saveSessionKey(
      String myUserId, String peerId, String b64) async {
    await _storage.write(key: 'session_${myUserId}_$peerId', value: b64);
  }

  Future<String?> getSessionKey(String myUserId, String peerId) async {
    return await _storage.read(key: 'session_${myUserId}_$peerId');
  }

  Future<void> deleteSessionKey(String myUserId, String peerId) async {
    await _storage.delete(key: 'session_${myUserId}_$peerId');
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
}
