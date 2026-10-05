import 'package:flutter/material.dart';
import '../core/l10n/s.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:permission_handler/permission_handler.dart';
import 'dart:async';
import '../core/network/websocket_service.dart';
import '../core/database/database_helper.dart';
import '../core/crypto/pairing_service.dart';
import 'chat_screen.dart';

class QrDisplayDialog extends StatelessWidget {
  final String userId;

  const QrDisplayDialog({super.key, required this.userId});

  @override
  Widget build(BuildContext context) {
    final displayData = userId.trim().isNotEmpty ? userId : 'WASL-UNKNOWN-ID';

    return AlertDialog(
      title:       Row(
        children: [
          Icon(Icons.qr_code_2, color: Colors.teal),
          SizedBox(width: 8),
          Text(S.yourQr),
        ],
      ),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
                Text(
            S.qrHint,
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 12, color: Colors.grey),
          ),
          const SizedBox(height: 16),
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(12),
            ),
            child: SizedBox(
              width: 200,
              height: 200,
              child: QrImageView(
                data: displayData,
                version: QrVersions.auto,
                size: 200.0,
                backgroundColor: Colors.white,
                errorCorrectionLevel: QrErrorCorrectLevel.M,
              ),
            ),
          ),
          const SizedBox(height: 12),
          SelectableText(
            displayData,
            style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child:       Text(S.close),
        ),
      ],
    );
  }
}

class QrScannerScreen extends StatefulWidget {
  final String currentUserId;

  const QrScannerScreen({super.key, required this.currentUserId});

  @override
  State<QrScannerScreen> createState() => _QrScannerScreenState();
}

class _QrScannerScreenState extends State<QrScannerScreen> with WidgetsBindingObserver {
  bool _scanned = false;
  StreamSubscription? _wsSub;
  MobileScannerController? _scannerController;
  bool _permissionGranted = false;
  bool _permissionChecked = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _checkPermissionAndCreateController();
  }

  Future<void> _checkPermissionAndCreateController() async {
    final status = await Permission.camera.request();
    if (!mounted) return;

    if (!status.isGranted) {
      setState(() {
        _permissionChecked = true;
        _permissionGranted = false;
      });
      return;
    }

    // Create the controller and the MobileScanner widget in the same build so
    // the plugin starts the camera from the widget's own initState (autoStart),
    // which is the timing the plugin is designed around. A manually deferred
    // start() previously raced the widget mount and could leave a black screen.
    final controller = MobileScannerController(
      detectionSpeed: DetectionSpeed.normal,
      facing: CameraFacing.back,
      torchEnabled: false,
      formats: const [BarcodeFormat.qrCode],
    );

    setState(() {
      _scannerController = controller;
      _permissionChecked = true;
      _permissionGranted = true;
    });
  }

  Future<void> _retryCamera() async {
    try {
      await _scannerController?.dispose();
    } catch (_) {}
    setState(() {
      _scannerController = null;
      _permissionChecked = false;
      _permissionGranted = false;
    });
    await _checkPermissionAndCreateController();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final controller = _scannerController;
    if (controller == null || !_permissionGranted) return;
    if (state == AppLifecycleState.resumed) {
      controller.start().catchError((_) {});
    } else if (state == AppLifecycleState.inactive ||
        state == AppLifecycleState.paused ||
        state == AppLifecycleState.hidden) {
      controller.stop().catchError((_) {});
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _wsSub?.cancel();
    _scannerController?.dispose();
    super.dispose();
  }

  Future<void> _startPairing(String rawTargetId) async {
    var cleanTarget = rawTargetId.trim().toUpperCase();
    if (cleanTarget.startsWith('WASL://')) {
      cleanTarget = cleanTarget.replaceFirst('WASL://', '');
    } else if (cleanTarget.startsWith('WASL:')) {
      cleanTarget = cleanTarget.replaceFirst('WASL:', '');
    }

    if (_scanned || cleanTarget.isEmpty) return;
    _scanned = true;

    try {
      await _scannerController?.stop();
    } catch (_) {}

    await PairingService()
        .sendPairRequest(myId: widget.currentUserId, targetId: cleanTarget);

    if (!mounted) return;

    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) => AlertDialog(
        title:       Text(S.sendingPairRequest),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const CircularProgressIndicator(color: Colors.teal),
            const SizedBox(height: 12),
            Text(S.waitingAccept),
          ],
        ),
      ),
    );

    _wsSub = WebSocketService().messageStream.listen((data) async {
      final type = data['type'];
      final senderId = (data['sender_id'] as String?)?.trim().toUpperCase();
      final recipientId = (data['recipient_id'] as String?)?.trim().toUpperCase();
      final myId = widget.currentUserId.trim().toUpperCase();

      if (recipientId != myId) return;

      if (type == 'pair_accept' && senderId != null) {
        // Derive session key and save peer keys
        final ok = await PairingService().handlePairAccept(data);
        if (ok) {
          final peerName = (data['display_name'] as String?)?.trim();
          await DatabaseHelper.instance.saveContact(
              senderId, peerName != null && peerName.isNotEmpty ? peerName : senderId, 'connected');

          if (!mounted) return;
          Navigator.of(context).pop(); // close dialog
          _wsSub?.cancel();
          Navigator.pushReplacement(
            context,
            MaterialPageRoute(
              builder: (context) => ChatScreen(
                currentUserId: myId,
                recipientId: senderId,
              ),
            ),
          );
        }
      } else if (type == 'pair_reject' && senderId == cleanTarget) {
        if (mounted) {
          Navigator.of(context).pop();
          _wsSub?.cancel();
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(S.pairRejected(senderId ?? ''))),
          );
          setState(() => _scanned = false);
          try {
            await _scannerController?.start();
          } catch (_) {}
        }
      }
    });
  }

  Future<void> _askManualEntry() async {
    final controller = TextEditingController();
    final result = await showDialog<String?>(
      context: context,
      builder: (context) => AlertDialog(
        title:       Text(S.manualIdEntry),
        content: TextField(
          controller: controller,
          decoration: const InputDecoration(
            hintText: 'WASL-XXXXXX',
            prefixIcon: Icon(Icons.security, color: Colors.teal),
          ),
          autofocus: true,
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context),
              child:       Text(S.cancel)),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: Colors.teal),
            onPressed: () => Navigator.pop(context, controller.text.trim()),
            child:       Text(S.sendRequest, style: TextStyle(color: Colors.white)),
          ),
        ],
      ),
    );

    if (result != null && result.isNotEmpty) {
      _startPairing(result);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        title:       Text(S.scanPairCode),
        backgroundColor: Colors.teal,
        foregroundColor: Colors.white,
        actions: [
          IconButton(
            icon: const Icon(Icons.keyboard),
            tooltip: S.manualEntry,
            onPressed: _askManualEntry,
          ),
          if (_scannerController != null)
            IconButton(
              icon: const Icon(Icons.flash_on),
              tooltip: S.flash,
              onPressed: () => _scannerController?.toggleTorch(),
            ),
        ],
      ),
      body: !_permissionChecked
          ?       Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  CircularProgressIndicator(color: Colors.tealAccent),
                  SizedBox(height: 16),
                  Text(S.startingCamera,
                      style: TextStyle(color: Colors.white70)),
                ],
              ),
            )
          : !_permissionGranted || _scannerController == null
              ? _buildPermissionOrErrorView()
              : Stack(
                  children: [
                    MobileScanner(
                      controller: _scannerController,
                      onDetect: (capture) {
                        if (_scanned) return;
                        for (final barcode in capture.barcodes) {
                          if (barcode.rawValue != null) {
                            final scanned = barcode.rawValue!.trim();
                            if (scanned.isNotEmpty) {
                              _startPairing(scanned);
                              break;
                            }
                          }
                        }
                      },
                    ),
                Center(
                  child: Container(
                    width: 260,
                    height: 260,
                    decoration: BoxDecoration(
                      border: Border.all(color: Colors.tealAccent, width: 2.5),
                      borderRadius: BorderRadius.circular(16),
                    ),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.end,
                      children: [
                        Padding(
                          padding: const EdgeInsets.only(bottom: 12.0),
                          child: Text(
                            S.pointCamera,
                            style: TextStyle(
                              color: Colors.white,
                              fontSize: 13,
                              fontWeight: FontWeight.bold,
                              shadows: [Shadow(blurRadius: 4, color: Colors.black)],
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                Positioned(
                  bottom: 30,
                  left: 0,
                  right: 0,
                  child: Center(
                    child: ElevatedButton.icon(
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.black87,
                        side: const BorderSide(color: Colors.teal),
                        padding: const EdgeInsets.symmetric(
                            horizontal: 20, vertical: 12),
                        shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(24)),
                      ),
                      icon: const Icon(Icons.keyboard, color: Colors.tealAccent),
                      label:       Text(
                        S.manualNoCamera,
                        style: TextStyle(color: Colors.white, fontSize: 14),
                      ),
                      onPressed: _askManualEntry,
                    ),
                  ),
                ),
              ],
            ),
    );
  }

  Widget _buildPermissionOrErrorView() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.camera_alt_outlined, size: 80, color: Colors.teal),
            const SizedBox(height: 20),
                  Text(
              S.cameraPermission,
              textAlign: TextAlign.center,
              style: TextStyle(color: Colors.white, fontSize: 16),
            ),
            const SizedBox(height: 24),
            ElevatedButton.icon(
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.teal,
                padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
              ),
              icon: const Icon(Icons.refresh, color: Colors.white),
              label:       Text(
                  S.grantPermission,
                  style: TextStyle(color: Colors.white, fontSize: 16)),
              onPressed: () async {
                final st = await Permission.camera.request();
                if (st.isPermanentlyDenied) {
                  await openAppSettings();
                  return;
                }
                _retryCamera();
              },
            ),
            const SizedBox(height: 16),
            TextButton.icon(
              icon: const Icon(Icons.keyboard, color: Colors.white70),
              label:       Text(
                S.orManual,
                style: TextStyle(color: Colors.white70, fontSize: 15),
              ),
              onPressed: _askManualEntry,
            ),
          ],
        ),
      ),
    );
  }
}
