import 'package:hive_flutter/hive_flutter.dart';
import '../models/message_model.dart';
import '../models/contact_model.dart';
import '../models/chat_model.dart';

class HiveStorageService {
  static const String messagesBoxName = 'encrypted_messages';
  static const String contactsBoxName = 'contacts';
  static const String chatsBoxName = 'chats';

  static Future<void> init() async {
    await Hive.initFlutter();

    if (!Hive.isAdapterRegistered(0)) Hive.registerAdapter(MessageTypeAdapter());
    if (!Hive.isAdapterRegistered(1)) Hive.registerAdapter(MessageStatusAdapter());
    if (!Hive.isAdapterRegistered(2)) Hive.registerAdapter(MessageModelAdapter());
    if (!Hive.isAdapterRegistered(3)) Hive.registerAdapter(ContactModelAdapter());
    if (!Hive.isAdapterRegistered(4)) Hive.registerAdapter(ChatModelAdapter());

    await Hive.openBox<MessageModel>(messagesBoxName);
    await Hive.openBox<ContactModel>(contactsBoxName);
    await Hive.openBox<ChatModel>(chatsBoxName);
  }

  Box<MessageModel> get messagesBox => Hive.box<MessageModel>(messagesBoxName);
  Box<ContactModel> get contactsBox => Hive.box<ContactModel>(contactsBoxName);
  Box<ChatModel> get chatsBox => Hive.box<ChatModel>(chatsBoxName);

  Future<void> saveMessage(MessageModel message) async {
    await messagesBox.put(message.id, message);
  }

  Future<void> saveContact(ContactModel contact) async {
    await contactsBox.put(contact.id, contact);
  }

  Future<void> saveChat(ChatModel chat) async {
    await chatsBox.put(chat.id, chat);
  }
}
