import 'package:flutter/foundation.dart';
import 'package:cryptography/cryptography.dart';
import '../models/message_model.dart';
import '../models/chat_model.dart';
import '../services/chat_service.dart';
import '../services/hive_storage_service.dart';

class ChatProvider extends ChangeNotifier {
  final ChatService chatService;
  final HiveStorageService storageService;

  List<ChatModel> _chats = [];
  List<MessageModel> _currentMessages = [];

  List<ChatModel> get chats => _chats;
  List<MessageModel> get currentMessages => _currentMessages;

  ChatProvider({
    required this.chatService,
    required this.storageService,
  }) {
    loadChats();
  }

  void loadChats() {
    _chats = storageService.chatsBox.values.toList();
    notifyListeners();
  }

  void loadMessagesForChat(String chatId) {
    _currentMessages = storageService.messagesBox.values
        .where((m) => m.senderId == chatId || m.receiverId == chatId)
        .toList();
    notifyListeners();
  }

  Future<void> sendTextMessage({
    required String messageId,
    required String senderId,
    required String receiverId,
    required String textContent,
    required SecretKey sharedSecretKey,
  }) async {
    await chatService.sendTextMessage(
      messageId: messageId,
      senderId: senderId,
      receiverId: receiverId,
      textContent: textContent,
      sharedSecretKey: sharedSecretKey,
    );

    loadMessagesForChat(receiverId);
  }
}
