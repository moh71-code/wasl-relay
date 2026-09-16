import 'package:hive/hive.dart';
import 'message_model.dart';

part 'chat_model.g.dart';

@HiveType(typeId: 4)
class ChatModel extends HiveObject {
  @HiveField(0)
  final String id;

  @HiveField(1)
  final String contactId;

  @HiveField(2)
  MessageModel? lastMessage;

  @HiveField(3)
  int unreadCount;

  ChatModel({
    required this.id,
    required this.contactId,
    this.lastMessage,
    this.unreadCount = 0,
  });
}
