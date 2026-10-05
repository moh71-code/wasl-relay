import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'package:cryptography/cryptography.dart';
import 'package:flutter/foundation.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
import '../storage/storage_service.dart';

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
  String? _registerNonce;
  String _serverHost = '127.0.0.1';
  int _serverPort = 8765;
  bool _useWss = false;

  Timer? _reconnectTimer;
  Timer? _heartbeatTimer;
  Timer? _registerTimeout;
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

  Future<void> connect(String userId,
      {String? serverIp, int? serverPort, bool? useWss, String? path}) async {
    _manuallyDisconnected = false;
    _currentUserId = userId;
    _registerNonce = null;
    if (serverIp != null && serverIp.isNotEmpty) _serverHost = serverIp;
    if (serverPort != null && serverPort > 0) _serverPort = serverPort;
    if (useWss != null) _useWss = useWss;

    _reconnectTimer?.cancel();
    _reconnectTimer = null;

    _setStatus('connecting');

    try {
      final scheme = _useWss ? 'wss' : 'ws';
      // Support both plain relay (ws://host:port) and path-based relay (wss://host/ws/userId)
      final effectivePath = (path != null && path.isNotEmpty)
          ? path
          : (_serverPort == 443 || _serverPort == 80 ? '/ws/$userId' : '');
      final uriStr = effectivePath.isEmpty
          ? '$scheme://$_serverHost:$_serverPort'
          : '$scheme://$_serverHost$effectivePath';
      final uri = Uri.parse(uriStr);
      debugPrint('WebSocket connecting to: $uri');

      _channel?.sink.close();
      _channel = WebSocketChannel.connect(uri);

      // Listen for messages
      _channel!.stream.listen(
        (message) {
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
              // Server challenge → answer with signed Ed25519 registration.
              if (data['type'] == 'challenge') {
                final nonce = data['nonce']?.toString();
                if (nonce != null) {
                  _registerNonce = nonce;
                  unawaited(_sendSignedRegister(nonce));
                }
                return;
              }
              // Auth confirmed by the relay — ONLY NOW are we "connected".
              // Gating on this ack prevents app/outbox frames from being
              // sent while the server still considers us unauthenticated
              // (they would be silently dropped otherwise).
              if (data['type'] == 'registered') {
                _registerTimeout?.cancel();
                if (_connectionState != 'connected') {
                  _setStatus('connected');
                  _reconnectAttempts = 0;
                  _startHeartbeat();
                }
                return;
              }
              if (data['type'] == 'register_error') {
                debugPrint(
                    'WebSocket: registration rejected: ${data['reason']}');
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

      // Wait until the connection is actually established before declaring
      // connected, otherwise messages sent here are silently dropped.
      try {
        final channel = _channel!;
        await channel.ready.timeout(const Duration(seconds: 10));
        // A concurrent reconnect may have replaced the channel while waiting.
        if (_channel != channel) return;
      } catch (e) {
        debugPrint('WebSocket Connection Failed: $e');
        _handleDisconnect();
        return;
      }

      // Registration is sent after the server's challenge frame arrives
      // (handled in the stream listener above). If the challenge was already
      // received, register now.
      if (_registerNonce != null) {
        final nonce = _registerNonce!;
        _registerNonce = null;
        await _sendSignedRegister(nonce);
      }

      // Safety: if no 'registered' ack arrives (old relay, stall), close the
      // socket so the normal reconnect-with-backoff path takes over instead
      // of sitting in 'connecting' forever.
      _registerTimeout?.cancel();
      _registerTimeout = Timer(const Duration(seconds: 8), () {
        if (_connectionState != 'connected') {
          debugPrint('WebSocket: no registered ack — restarting connection');
          try {
            _channel?.sink.close();
          } catch (_) {}
        }
      });
    } catch (e) {
      debugPrint('WebSocket Connection Failed: $e');
      _handleDisconnect();
    }
  }

  /// Sign the server's challenge with our Ed25519 identity key and register.
  /// Proves to the relay that we own this user_id without revealing anything.
  Future<void> _sendSignedRegister(String nonce) async {
    final userId = _currentUserId;
    if (userId == null) return;
    try {
      final storage = StorageService();
      final edPubB64 = await storage.getEdPublicKey(userId);
      final edPrivB64 = await storage.getEdPrivateKey(userId);
      if (edPubB64 == null || edPrivB64 == null) {
        debugPrint('WebSocket: identity keys missing — cannot register');
        return;
      }
      final ed = Ed25519();
      final keyPair = await ed.newKeyPairFromSeed(base64.decode(edPrivB64));
      final msg = utf8.encode('wasl-register|$userId|$nonce');
      final sig = await ed.sign(msg, keyPair: keyPair);
      _registerNonce = null;
      // Bypass sendData's isConnected gate — registration happens BEFORE the
      // 'connected' state (which is only set on the server's 'registered' ack).
      _channel?.sink.add(jsonEncode({
        'type': 'register',
        'user_id': userId,
        'public_key': edPubB64,
        'nonce': nonce,
        'signature': base64Encode(sig.bytes),
      }));
    } catch (e) {
      debugPrint('WebSocket: signed register failed: $e');
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
    _registerTimeout?.cancel();
    _setStatus('disconnected');
    try {
      _channel?.sink.close();
    } catch (_) {}
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
    int? timestamp,
    String? signature,
  }) {
    sendData({
      'type': 'delete_message',
      'message_uuid': messageUuid,
      'sender_id': senderId,
      'recipient_id': recipientId,
      if (signature != null) 'signature': signature,
      'timestamp': timestamp ?? DateTime.now().millisecondsSinceEpoch,
    });
  }

  void sendData(Map<String, dynamic> data) {
    // Gate on FULLY-AUTHENTICATED state — the relay drops frames from
    // unauthenticated connections, so sending earlier loses them silently.
    if (_channel != null && isConnected) {
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
    _registerTimeout?.cancel();
    _channel?.sink.close();
    _channel = null;
    _setStatus('disconnected');
  }
}
