import 'package:hive/hive.dart';

part 'contact_model.g.dart';

@HiveType(typeId: 3)
class ContactModel extends HiveObject {
  @HiveField(0)
  final String id;

  @HiveField(1)
  final String name;

  @HiveField(2)
  final String publicKeyPem;

  @HiveField(3)
  final String? avatarUrl;

  ContactModel({
    required this.id,
    required this.name,
    required this.publicKeyPem,
    this.avatarUrl,
  });
}
