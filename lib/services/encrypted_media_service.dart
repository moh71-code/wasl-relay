import 'dart:typed_data';
import 'package:cryptography/cryptography.dart';
import 'crypto_service.dart';

class EncryptedMediaService {
  final CryptoService _cryptoService;

  EncryptedMediaService(this._cryptoService);

  /// تشفير ملف ميديا (Bytes) باستخدام AES-256-GCM
  Future<Map<String, dynamic>> encryptMediaBytes({
    required Uint8List rawBytes,
    required SecretKey secretKey,
  }) async {
    final secretBox = await _cryptoService.encryptPayload(
      plainText: rawBytes,
      secretKey: secretKey,
    );

    return {
      'cipherText': secretBox.cipherText,
      'nonce': secretBox.nonce,
      'mac': secretBox.mac.bytes,
    };
  }

  /// فك تشفير ملف ميديا مباشرة في الذاكرة (In-Memory Streaming / Playback)
  Future<Uint8List> decryptMediaToBytes({
    required List<int> cipherText,
    required List<int> nonce,
    required List<int> macBytes,
    required SecretKey secretKey,
  }) async {
    final secretBox = SecretBox(
      cipherText,
      nonce: nonce,
      mac: Mac(macBytes),
    );

    final decryptedList = await _cryptoService.decryptPayload(
      secretBox: secretBox,
      secretKey: secretKey,
    );

    return Uint8List.fromList(decryptedList);
  }
}
