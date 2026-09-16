import 'dart:async';

abstract class MessageTransport {
  Stream<Map<String, dynamic>> get messageStream;
  Future<void> connect();
  Future<void> disconnect();
  Future<void> sendMessage(Map<String, dynamic> payload);
}

class LocalLoopbackTransport implements MessageTransport {
  final _controller = StreamController<Map<String, dynamic>>.broadcast();

  @override
  Stream<Map<String, dynamic>> get messageStream => _controller.stream;

  @override
  Future<void> connect() async {}

  @override
  Future<void> disconnect() async {
    await _controller.close();
  }

  @override
  Future<void> sendMessage(Map<String, dynamic> payload) async {
    _controller.add(payload);
  }
}
