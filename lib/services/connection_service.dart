import 'dart:convert';
import 'package:cryptography/cryptography.dart';

class ConnectionService {
  final Ed25519 _ed25519 = Ed25519();

  /// إنشاء كود ربط / QR يحتوي على المفاتيح العامة ورقم الهوية
  Future<String> generateConnectionPayload({
    required String myId,
    required SimplePublicKey x25519PublicKey,
    required SimplePublicKey ed25519PublicKey,
  }) async {
    final payload = {
      'id': myId,
      'x25519': base64Encode(x25519PublicKey.bytes),
      'ed25519': base64Encode(ed25519PublicKey.bytes),
    };

    return jsonEncode(payload);
  }

  /// تحليل الـ Payload المستلم من الـ QR Code الخاص بالطرف الآخر
  Map<String, dynamic> parseConnectionPayload(String jsonPayload) {
    return jsonDecode(jsonPayload) as Map<String, dynamic>;
  }

  /// التحقق من التوقيع الرقمي للطرف الآخر لمنع هجمات (MITM)
  Future<bool> verifyPeerSignature({
    required List<int> messageBytes,
    required List<int> signatureBytes,
    required PublicKey peerEd25519PublicKey,
  }) async {
    final signature = Signature(
      signatureBytes,
      publicKey: peerEd25519PublicKey,
    );

    return await _ed25519.verify(
      messageBytes,
      signature: signature,
    );
  }
}
