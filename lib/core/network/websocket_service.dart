import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'package:flutter/foundation.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

class WebSocketService {
  static final WebSocketService _instance = WebSocketService._internal();
  factory WebSocketService() => _instance;
  WebSocketService._internal();

  WebSocketChannel? _channel;
  final StreamController<Map<String, dynamic>> _messageController =
      StreamController<Map<String, dynamic>>.broadcast();
  final StreamController<String> _statusController =
      StreamController<String>.broadcast();

  Stream<Map<String, dynamic>> get messageStream => _messageController.stream;
  Stream<String> get statusStream => _statusController.stream;

  String _connectionState = 'disconnected';
  String get connectionState => _connectionState;
  bool get isConnected => _connectionState == 'connected' && _channel != null;

  String? _currentUserId;
  String _serverHost = '127.0.0.1';
  int _serverPort = 8765;
  bool _useWss = false;

  Timer? _reconnectTimer;
  Timer? _heartbeatTimer;
  int _reconnectAttempts = 0;
  bool _manuallyDisconnected = false;

  void _setStatus(String state) {
    _connectionState = state;
    _statusController.add(state);
  }

  /// Emit a local event into the message stream (does not send to server).
  void emitLocal(Map<String, dynamic> data) {
    _messageController.add(data);
  }

  void configure({
    String? host,
    int? port,
    bool? useWss,
  }) {
    if (host != null && host.isNotEmpty) _serverHost = host;
    if (port != null && port > 0) _serverPort = port;
    if (useWss != null) _useWss = useWss;
  }

  void connect(String userId, {String? serverIp, int? serverPort, bool? useWss}) {
    _manuallyDisconnected = false;
    _currentUserId = userId;
    if (serverIp != null && serverIp.isNotEmpty) _serverHost = serverIp;
    if (serverPort != null && serverPort > 0) _serverPort = serverPort;
    if (useWss != null) _useWss = useWss;

    _reconnectTimer?.cancel();
    _reconnectTimer = null;

    _setStatus('connecting');

    try {
      final scheme = _useWss ? 'wss' : 'ws';
      final uri = Uri.parse('$scheme://$_serverHost:$_serverPort');
      
      _channel?.sink.close();
      _channel = WebSocketChannel.connect(uri);

      // Listen for messages
      _channel!.stream.listen(
        (message) {
          if (_connectionState != 'connected') {
            _setStatus('connected');
            _reconnectAttempts = 0;
            _startHeartbeat();
          }

          try {
            final data = jsonDecode(message as String);
            if (data is Map<String, dynamic>) {
              // Respond to server ping
              if (data['type'] == 'ping') {
                sendData({'type': 'pong'});
                return;
              }
              if (data['type'] == 'pong') {
                return;
              }
              _messageController.add(data);
            }
          } catch (e) {
            debugPrint('Error decoding WebSocket data: $e');
          }
        },
        onError: (error) {
          debugPrint('WebSocket Error: $error');
          _handleDisconnect();
        },
        onDone: () {
          debugPrint('WebSocket Connection Closed');
          _handleDisconnect();
        },
      );

      // Send registration payload
      sendData({
        'type': 'register',
        'user_id': userId,
      });

      _setStatus('connected');
      _reconnectAttempts = 0;
      _startHeartbeat();
    } catch (e) {
      debugPrint('WebSocket Connection Failed: $e');
      _handleDisconnect();
    }
  }

  void _startHeartbeat() {
    _heartbeatTimer?.cancel();
    _heartbeatTimer = Timer.periodic(const Duration(seconds: 25), (_) {
      if (isConnected) {
        sendData({'type': 'ping'});
      }
    });
  }

  void _handleDisconnect() {
    _heartbeatTimer?.cancel();
    _setStatus('disconnected');
    _channel = null;

    if (!_manuallyDisconnected && _currentUserId != null) {
      _scheduleReconnect();
    }
  }

  void _scheduleReconnect() {
    _reconnectTimer?.cancel();
    _reconnectAttempts++;
    final delaySeconds = min(30, pow(2, _reconnectAttempts).toInt());
    debugPrint('WebSocket: Scheduling reconnect in $delaySeconds seconds (attempt $_reconnectAttempts)');

    _reconnectTimer = Timer(Duration(seconds: delaySeconds), () {
      if (!_manuallyDisconnected && _currentUserId != null) {
        connect(_currentUserId!);
      }
    });
  }

  /// إرسال رسالة مشفرة عبر الـ WebSocket
  void sendEncryptedMessage({
    required String recipientId,
    required String senderId,
    required Map<String, String> encryptedPayload,
  }) {
    sendData({
      'type': 'encrypted_message',
      'sender_id': senderId,
      'recipient_id': recipientId,
      'payload': encryptedPayload,
      'timestamp': DateTime.now().millisecondsSinceEpoch,
    });
  }

  /// Send delivery acknowledgment to sender
  void sendDeliveryAck({
    required String messageUuid,
    required String senderId,
    required String recipientId,
  }) {
    sendData({
      'type': 'delivery_ack',
      'message_uuid': messageUuid,
      'sender_id': senderId,
      'recipient_id': recipientId,
      'timestamp': DateTime.now().millisecondsSinceEpoch,
    });
  }

  /// Send read acknowledgment to sender
  void sendReadAck({
    required List<String> messageUuids,
    required String senderId,
    required String recipientId,
  }) {
    if (messageUuids.isEmpty) return;
    sendData({
      'type': 'read_ack',
      'message_uuids': messageUuids,
      'sender_id': senderId,
      'recipient_id': recipientId,
      'timestamp': DateTime.now().millisecondsSinceEpoch,
    });
  }

  /// Send delete for everyone request
  void sendDeleteMessage({
    required String messageUuid,
    required String senderId,
    required String recipientId,
    String? signature,
  }) {
    sendData({
      'type': 'delete_message',
      'message_uuid': messageUuid,
      'sender_id': senderId,
      'recipient_id': recipientId,
      if (signature != null) 'signature': signature,
      'timestamp': DateTime.now().millisecondsSinceEpoch,
    });
  }

  void sendData(Map<String, dynamic> data) {
    if (_channel != null) {
      try {
        _channel!.sink.add(jsonEncode(data));
      } catch (e) {
        debugPrint('Failed to send data over WebSocket: $e');
      }
    }
  }

  void disconnect() {
    _manuallyDisconnected = true;
    _reconnectTimer?.cancel();
    _heartbeatTimer?.cancel();
    _channel?.sink.close();
    _channel = null;
    _setStatus('disconnected');
  }
}
