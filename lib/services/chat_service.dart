import 'dart:convert';
import 'package:cryptography/cryptography.dart';
import '../models/message_model.dart';
import 'crypto_service.dart';
import 'hive_storage_service.dart';
import 'message_transport.dart';

class ChatService {
  final CryptoService cryptoService;
  final HiveStorageService storageService;
  final MessageTransport transport;

  ChatService({
    required this.cryptoService,
    required this.storageService,
    required this.transport,
  });

  /// تشفير وإرسال رسالة نصية
  Future<void> sendTextMessage({
    required String messageId,
    required String senderId,
    required String receiverId,
    required String textContent,
    required SecretKey sharedSecretKey,
  }) async {
    final plainBytes = utf8.encode(textContent);
    final secretBox = await cryptoService.encryptPayload(
      plainText: plainBytes,
      secretKey: sharedSecretKey,
    );

    final encryptedContentHex = base64Encode(secretBox.cipherText);
    final nonceHex = base64Encode(secretBox.nonce);

    final messageModel = MessageModel(
      id: messageId,
      senderId: senderId,
      receiverId: receiverId,
      encryptedContent: encryptedContentHex,
      type: MessageType.text,
      timestamp: DateTime.now(),
      status: MessageStatus.sent,
      nonce: nonceHex,
    );

    await storageService.saveMessage(messageModel);

    await transport.sendMessage({
      'id': messageId,
      'senderId': senderId,
      'receiverId': receiverId,
      'content': encryptedContentHex,
      'nonce': nonceHex,
      'type': 'text',
      'timestamp': messageModel.timestamp.toIso8601String(),
    });
  }
}
