import 'dart:convert';
import 'package:cryptography/cryptography.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

class CryptoService {
  final X25519 _x25519 = X25519();
  final AesGcm _aesGcm = AesGcm.with256bits();
  final FlutterSecureStorage _secureStorage = const FlutterSecureStorage();

  static const String _storageKeyX25519Private = 'wasl_x25519_private_seed';

  /// استرجاع أو توليد زوج مفاتيح X25519 وحفظه بأمان تام في التخزين المشفر
  Future<SimpleKeyPair> getOrCreateX25519KeyPair() async {
    try {
      final storedSeed =
          await _secureStorage.read(key: _storageKeyX25519Private);
      if (storedSeed != null) {
        final seedList = jsonDecode(storedSeed).cast<int>();
        return await _x25519.newKeyPairFromSeed(seedList);
      }
    } catch (_) {}

    final newKeyPair = await _x25519.newKeyPair();
    final privateKeyBytes = await newKeyPair.extractPrivateKeyBytes();
    await _secureStorage.write(
      key: _storageKeyX25519Private,
      value: jsonEncode(privateKeyBytes),
    );
    return newKeyPair;
  }

  // ==================== الدوال الأصلية الخاصة بك (محفوظة بالكامل) ====================

  Future<SimpleKeyPair> generateX25519KeyPair() async {
    return await _x25519.newKeyPair();
  }

  Future<SecretKey> deriveSharedSecret({
    required SimpleKeyPair myPrivateKey,
    required PublicKey remotePublicKey,
  }) async {
    return await _x25519.sharedSecretKey(
      keyPair: myPrivateKey,
      remotePublicKey: remotePublicKey,
    );
  }

  Future<SecretBox> encryptPayload({
    required List<int> plainText,
    required SecretKey secretKey,
  }) async {
    return await _aesGcm.encrypt(
      plainText,
      secretKey: secretKey,
    );
  }

  Future<List<int>> decryptPayload({
    required SecretBox secretBox,
    required SecretKey secretKey,
  }) async {
    return await _aesGcm.decrypt(
      secretBox,
      secretKey: secretKey,
    );
  }
}
