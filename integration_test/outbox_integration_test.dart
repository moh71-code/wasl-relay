import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:wasl_app/core/database/database_helper.dart';
import 'package:wasl_app/core/network/websocket_service.dart';

void main() {
  testWidgets('Outbox offline_file -> processOutbox integration',
      (tester) async {
    final messages = <String>[];
    // start local websocket server
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 8765);
    server.transform(WebSocketTransformer()).listen((WebSocket ws) {
      ws.listen((data) {
        messages.add(data.toString());
      });
    });

    // ensure DB is open
    await DatabaseHelper.instance.database;

    // connect client to local server
    WebSocketService().connect('tester', serverIp: '127.0.0.1');

    // construct a tiny offline_file envelope and enqueue
    final envelope = {
      'type': 'offline_file',
      'file_id': 'test-file-1',
      'sender_id': 'tester',
      'recipient_id': 'recipient',
      'ciphertext_b64': base64.encode(utf8.encode('dummy')),
      'nonce': 'n',
      'mac': 'm',
      'original_name': 'dummy.txt',
      'chunk_size': 4,
    };

    await DatabaseHelper.instance.enqueueOutbox(jsonEncode(envelope));

    // wait a moment for WS connection
    await Future.delayed(const Duration(seconds: 1));

    // process outbox which should send chunks to the local server
    await DatabaseHelper.instance.processOutbox();

    // give some time for messages to arrive
    await Future.delayed(const Duration(seconds: 1));

    // shutdown server
    await server.close(force: true);

    // validate we received at least one chunk payload
    expect(messages.isNotEmpty, true);
  }, timeout: Timeout(Duration(seconds: 30)));
}
