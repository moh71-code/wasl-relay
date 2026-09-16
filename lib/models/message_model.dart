import 'package:hive/hive.dart';

part 'message_model.g.dart';

@HiveType(typeId: 0)
enum MessageType {
  @HiveField(0)
  text,
  @HiveField(1)
  audio,
  @HiveField(2)
  image,
  @HiveField(3)
  video,
}

@HiveType(typeId: 1)
enum MessageStatus {
  @HiveField(0)
  sending,
  @HiveField(1)
  sent,
  @HiveField(2)
  delivered,
  @HiveField(3)
  read,
  @HiveField(4)
  failed,
}

@HiveType(typeId: 2)
class MessageModel extends HiveObject {
  @HiveField(0)
  final String id;

  @HiveField(1)
  final String senderId;

  @HiveField(2)
  final String receiverId;

  @HiveField(3)
  final String encryptedContent;

  @HiveField(4)
  final MessageType type;

  @HiveField(5)
  final DateTime timestamp;

  @HiveField(6)
  MessageStatus status;

  @HiveField(7)
  final String? nonce;

  MessageModel({
    required this.id,
    required this.senderId,
    required this.receiverId,
    required this.encryptedContent,
    required this.type,
    required this.timestamp,
    this.status = MessageStatus.sending,
    this.nonce,
  });
}
