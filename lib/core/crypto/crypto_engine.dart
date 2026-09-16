import 'dart:convert';
import 'package:cryptography/cryptography.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

class CryptoEngine {
  final _x25519 = X25519();
  final _aesGcm = AesGcm.with256bits();
  final _secureStorage = const FlutterSecureStorage();

  // مفاتيح التخزين الآمن
  static const String _privateKeyStorageKey = 'wasl_user_private_key';

  /// توليد مفتاح جديد أو استرجاعه من التخزين الآمن للجهاز
  Future<SimpleKeyPair> getOrCreateKeyPair() async {
    try {
      final storedPrivateKeyBytes =
          await _secureStorage.read(key: _privateKeyStorageKey);
      if (storedPrivateKeyBytes != null) {
        // استعادة المفتاح المخزن سابقاً
        final privateKeyList = jsonDecode(storedPrivateKeyBytes).cast<int>();
        return await _x25519.newKeyPairFromSeed(privateKeyList);
      }
    } catch (_) {
      // في حال حدث خطأ يتم توليد زوج مفاتيح جديد
    }

    // توليد زوج مفاتيح جديد كلياً
    final newKeyPair = await _x25519.newKeyPair();
    final privateKeyBytes = await newKeyPair.extractPrivateKeyBytes();

    // حفظ المفتاح الخاص بأمان تام داخل الجهاز
    await _secureStorage.write(
      key: _privateKeyStorageKey,
      value: jsonEncode(privateKeyBytes),
    );

    return newKeyPair;
  }

  /// تصدير المفتاح العام لمشاركته عبر QR Code أو بروتوكول الاتصال (بتنسيق Base64)
  Future<String> exportPublicKeyBase64(SimpleKeyPair keyPair) async {
    final publicKey = await keyPair.extractPublicKey();
    return base64.encode(publicKey.bytes);
  }

  /// استيراد المفتاح العام للطرف الآخر من نص Base64
  PublicKey importPublicKeyFromBase64(String base64PublicKey) {
    final bytes = base64.decode(base64PublicKey);
    return SimplePublicKey(bytes, type: KeyPairType.x25519);
  }

  // ==================== الدوال الأصلية الخاصة بك (تم الاحتفاظ بها بالكامل) ====================

  Future<SimpleKeyPair> generateKeyPair() async {
    return await _x25519.newKeyPair();
  }

  Future<SecretKey> deriveSharedKey({
    required SimpleKeyPair myPrivateKey,
    required PublicKey remotePublicKey,
  }) async {
    return await _x25519.sharedSecretKey(
      keyPair: myPrivateKey,
      remotePublicKey: remotePublicKey,
    );
  }

  Future<Map<String, String>> encryptMessage({
    required String plainText,
    required SecretKey sharedKey,
  }) async {
    final secretBox = await _aesGcm.encrypt(
      utf8.encode(plainText),
      secretKey: sharedKey,
    );

    return {
      'ciphertext': base64.encode(secretBox.cipherText),
      'nonce': base64.encode(secretBox.nonce),
      'mac': base64.encode(secretBox.mac.bytes),
    };
  }

  Future<Map<String, String>> encryptBytes({
    required List<int> plainBytes,
    required SecretKey sharedKey,
  }) async {
    final secretBox = await _aesGcm.encrypt(
      plainBytes,
      secretKey: sharedKey,
    );

    return {
      'ciphertext': base64.encode(secretBox.cipherText),
      'nonce': base64.encode(secretBox.nonce),
      'mac': base64.encode(secretBox.mac.bytes),
    };
  }

  Future<String> decryptMessage({
    required String cipherTextBase64,
    required String nonceBase64,
    required String macBase64,
    required SecretKey sharedKey,
  }) async {
    final secretBox = SecretBox(
      base64.decode(cipherTextBase64),
      nonce: base64.decode(nonceBase64),
      mac: Mac(base64.decode(macBase64)),
    );

    final clearBytes = await _aesGcm.decrypt(
      secretBox,
      secretKey: sharedKey,
    );

    return utf8.decode(clearBytes);
  }

  Future<List<int>> decryptBytes({
    required String cipherTextBase64,
    required String nonceBase64,
    required String macBase64,
    required SecretKey sharedKey,
  }) async {
    final secretBox = SecretBox(
      base64.decode(cipherTextBase64),
      nonce: base64.decode(nonceBase64),
      mac: Mac(base64.decode(macBase64)),
    );

    final clearBytes = await _aesGcm.decrypt(
      secretBox,
      secretKey: sharedKey,
    );

    return clearBytes;
  }
}
