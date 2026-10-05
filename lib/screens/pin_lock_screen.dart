import 'dart:async';
import '../core/l10n/s.dart';
import 'dart:convert';
import 'dart:math';
import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../core/storage/storage_service.dart';
import '../core/theme/app_theme.dart';
import '../providers/settings_provider.dart';

/// Salted SHA-256 helpers for the app-lock PIN. The raw PIN is never stored;
/// secure storage only keeps `v1:<saltHex>:<hashHex>`.
class PinCrypto {
  static String createStoredValue(String pin) {
    final salt = List<int>.generate(16, (_) => Random.secure().nextInt(256));
    final saltHex = salt.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
    final hash = sha256.convert([...salt, ...utf8.encode(pin)]);
    return 'v1:$saltHex:${hash.toString()}';
  }

  static bool verify(String pin, String stored) {
    try {
      final parts = stored.split(':');
      if (parts.length != 3 || parts[0] != 'v1') return false;
      final salt = <int>[];
      for (var i = 0; i < parts[1].length; i += 2) {
        salt.add(int.parse(parts[1].substring(i, i + 2), radix: 16));
      }
      final hash = sha256.convert([...salt, ...utf8.encode(pin)]).toString();
      return hash == parts[2];
    } catch (_) {
      return false;
    }
  }
}

/// Full-screen numeric PIN pad. Calls [onUnlock] once the correct PIN is
/// entered; enforces a cooldown after repeated wrong attempts.
class PinLockScreen extends StatefulWidget {
  final VoidCallback onUnlock;

  const PinLockScreen({super.key, required this.onUnlock});

  @override
  State<PinLockScreen> createState() => _PinLockScreenState();
}

class _PinLockScreenState extends State<PinLockScreen> with TickerProviderStateMixin {
  static const int _maxDigits = 6;
  static const int _maxAttempts = 5;
  static const Duration _cooldown = Duration(seconds: 30);

  String _entered = '';
  String? _error;
  int _failedAttempts = 0;
  int _cooldownRemaining = 0;
  Timer? _cooldownTimer;
  late AnimationController _shakeController;
  
  @override
  void initState() {
    super.initState();
    _shakeController = AnimationController(
      duration: const Duration(milliseconds: 500),
      vsync: this,
    );
  }
  
  @override
  void dispose() {
    _cooldownTimer?.cancel();
    _shakeController.dispose();
    super.dispose();
  }

  bool get _keypadEnabled =>
      _cooldownRemaining == 0 && _entered.length < _maxDigits;

  void _onDigit(String digit) {
    if (!_keypadEnabled) return;
    setState(() {
      _entered += digit;
      _error = null;
    });
    if (_entered.length == _maxDigits) {
      _tryUnlock();
    }
  }

  void _onBackspace() {
    if (_cooldownRemaining > 0 || _entered.isEmpty) return;
    setState(() => _entered = _entered.substring(0, _entered.length - 1));
  }

  Future<void> _tryUnlock() async {
    final pin = _entered;
    final stored = await StorageService().getPinHash();
    if (!mounted) return;
    if (stored != null && PinCrypto.verify(pin, stored)) {
      widget.onUnlock();
      return;
    }
    
    // Shake animation for wrong PIN
    _shakeController.forward().then((_) {
      _shakeController.reverse();
    });
    
    _failedAttempts++;
    if (_failedAttempts >= _maxAttempts) {
      _startCooldown();
    }
    setState(() {
      _entered = '';
      _error = _cooldownRemaining > 0
          ? null
          : S.wrongPin;
    });
  }

  void _startCooldown() {
    _failedAttempts = 0;
    _cooldownRemaining = _cooldown.inSeconds;
    _cooldownTimer?.cancel();
    _cooldownTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (!mounted) {
        timer.cancel();
        return;
      }
      setState(() => _cooldownRemaining--);
      if (_cooldownRemaining <= 0) {
        timer.cancel();
        _cooldownRemaining = 0;
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Container(
        decoration: BoxDecoration(
          gradient: AppTheme.primaryGradient,
        ),
        child: SafeArea(
          child: Column(
            children: [
              const Spacer(flex: 2),
              
              // Logo
              AnimatedBuilder(
                animation: _shakeController,
                builder: (context, child) {
                  return Transform.translate(
                    offset: Offset(_shakeController.value * 10, 0),
                    child: child,
                  );
                },
                child: Container(
                  width: 100,
                  height: 100,
                  decoration: BoxDecoration(
                    color: Colors.white.withValues(alpha: 0.2),
                    borderRadius: BorderRadius.circular(25),
                    border: Border.all(color: Colors.white.withValues(alpha: 0.3), width: 2),
                  ),
                  child: const Icon(
                    Icons.lock_rounded,
                    size: 50,
                    color: Colors.white,
                  ),
                ),
              ),
              
              const SizedBox(height: 24),
              
                    Text(
                S.appLocked,
                style: TextStyle(
                    fontSize: 28,
                    fontWeight: FontWeight.bold,
                    color: Colors.white),
              ),

              const SizedBox(height: 8),

              Text(
                _cooldownRemaining > 0
                    ? S.tooManyAttempts(_cooldownRemaining)
                    : S.enterPin,
                textAlign: TextAlign.center,
                style: TextStyle(
                    fontSize: 16,
                    color: Colors.white70),
              ),
              
              const SizedBox(height: 32),
              
              // PIN Dots
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: List.generate(_maxDigits, (i) {
                  final filled = i < _entered.length;
                  return AnimatedContainer(
                    duration: const Duration(milliseconds: 200),
                    margin: const EdgeInsets.symmetric(horizontal: 8),
                    width: 16,
                    height: 16,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: filled ? Colors.white : Colors.white24,
                      border: Border.all(color: Colors.white54),
                    ),
                  );
                }),
              ),
              
              if (_error != null) ...[
                const SizedBox(height: 16),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                  decoration: BoxDecoration(
                    color: Colors.white.withValues(alpha: 0.2),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text(_error!,
                      style: const TextStyle(color: Colors.white, fontSize: 14)),
                ),
              ],
              
              const Spacer(flex: 2),
              
              // Keypad
              _buildKeypad(),
              
              const SizedBox(height: 24),
              
              // Unlock Button
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 40),
                child: SizedBox(
                  width: double.infinity,
                  height: 56,
                  child: Container(
                    decoration: BoxDecoration(
                      color: Colors.white.withValues(alpha: 0.2),
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(color: Colors.white.withValues(alpha: 0.3)),
                    ),
                    child: Material(
                      color: Colors.transparent,
                      child: InkWell(
                        onTap: _entered.length >= 4 && _cooldownRemaining == 0
                            ? _tryUnlock
                            : null,
                        borderRadius: BorderRadius.circular(16),
                        child:       Center(
                          child: Row(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Icon(Icons.lock_open_rounded, color: Colors.white),
                              SizedBox(width: 8),
                              Text(
                                S.unlock,
                                style: TextStyle(
                                    color: Colors.white,
                                    fontSize: 18,
                                    fontWeight: FontWeight.bold),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
              
              const SizedBox(height: 24),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildKeypad() {
    final keys = ['1', '2', '3', '4', '5', '6', '7', '8', '9', '', '0', '⌫'];
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 40),
      child: GridView.count(
        crossAxisCount: 3,
        shrinkWrap: true,
        mainAxisSpacing: 16,
        crossAxisSpacing: 16,
        childAspectRatio: 1.4,
        physics: const NeverScrollableScrollPhysics(),
        children: keys.map((key) {
          if (key.isEmpty) return const SizedBox.shrink();
          final isBackspace = key == '⌫';
          return Material(
            color: Colors.white.withValues(alpha: 0.15),
            shape: const CircleBorder(),
            child: InkWell(
              customBorder: const CircleBorder(),
              onTap: isBackspace ? _onBackspace : () => _onDigit(key),
              child: Center(
                child: isBackspace
                    ? const Icon(Icons.backspace_outlined,
                        color: Colors.white70, size: 28)
                    : Text(key,
                        style: const TextStyle(
                            fontSize: 28,
                            color: Colors.white,
                            fontWeight: FontWeight.bold)),
              ),
            ),
          );
        }).toList(),
      ),
    );
  }
}

/// Wraps the whole app (via MaterialApp.builder) and shows the PIN lock screen
/// on cold start and whenever the app returns from the background, as long as
/// a PIN is configured in settings.
class AppLockGate extends StatefulWidget {
  final Widget child;

  const AppLockGate({super.key, required this.child});

  @override
  State<AppLockGate> createState() => _AppLockGateState();
}

class _AppLockGateState extends State<AppLockGate> with TickerProviderStateMixin, WidgetsBindingObserver {
  bool? _locked;
  late AnimationController _fadeController;
  int _backgroundedAt = 0;

  @override
  void initState() {
    super.initState();
    _fadeController = AnimationController(
      duration: const Duration(milliseconds: 300),
      vsync: this,
    );
    WidgetsBinding.instance.addObserver(this);
    _checkPinConfigured();
  }

  @override
  void dispose() {
    _fadeController.dispose();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  Future<void> _checkPinConfigured() async {
    final configured = (await StorageService().getPinHash()) != null;
    if (!mounted) return;
    setState(() => _locked = configured);
    _fadeController.forward();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (_locked != false) return;
    // Never lock when the user has not enabled the PIN lock — doing so would
    // trap them on an unlock screen with no valid PIN (requires app restart).
    final settings = context.read<SettingsProvider>();
    if (!settings.pinLockEnabled) return;
    // NOTE: `hidden` fires on BOTH the backgrounding AND foregrounding paths
    // on Android — recording the timestamp there would reset the elapsed time
    // to ~0 on every resume, so a delayed auto-lock would never trigger.
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.detached) {
      _backgroundedAt = DateTime.now().millisecondsSinceEpoch;
      // "Lock immediately" hides content the moment the app leaves foreground
      if (settings.autoLockSeconds == 0) {
        setState(() => _locked = true);
      }
    } else if (state == AppLifecycleState.resumed) {
      if (settings.autoLockSeconds > 0 && _backgroundedAt > 0) {
        final elapsedSec =
            (DateTime.now().millisecondsSinceEpoch - _backgroundedAt) ~/ 1000;
        if (elapsedSec >= settings.autoLockSeconds) {
          setState(() => _locked = true);
        }
        _backgroundedAt = 0;
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    // Safety net: if the PIN was disabled (or removed) while a lock screen is
    // somehow up, release it instead of trapping the user.
    if (_locked == true &&
        !context.watch<SettingsProvider>().pinLockEnabled) {
      _locked = false;
    }
    final locked = _locked;
    if (locked == null) {
      return const Scaffold(
        body: Center(
          child: CircularProgressIndicator(color: AppTheme.primaryColor),
        ),
      );
    }
    if (locked) {
      return PinLockScreen(
        onUnlock: () {
          setState(() => _locked = false);
        },
      );
    }
    return FadeTransition(
      opacity: _fadeController,
      child: widget.child,
    );
  }
}
