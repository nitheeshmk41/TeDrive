// App Lock: Protects the app with a secure PIN.
// PIN is hashed with PBKDF2-HMAC-SHA256 and stored in flutter_secure_storage.

import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

class AppLockService {
  AppLockService._();
  static final AppLockService instance = AppLockService._();

  static const _pinHashKey = 'tedrive_app_lock_pin_hash';
  static const _pinSaltKey = 'tedrive_app_lock_pin_salt';
  static const _storage = FlutterSecureStorage();

  bool _isUnlocked = false;
  bool _isConfigured = false;

  bool get isUnlocked => !_isConfigured || _isUnlocked;
  bool get isConfigured => _isConfigured;

  Future<void> init() async {
    try {
      final hash = await _storage.read(key: _pinHashKey);
      _isConfigured = hash != null && hash.isNotEmpty;
    } catch (_) {
      _isConfigured = false;
    }
  }

  void lock() {
    _isUnlocked = false;
  }

  Future<bool> verifyPin(String enteredPin) async {
    try {
      final storedHash = await _storage.read(key: _pinHashKey);
      final storedSalt = await _storage.read(key: _pinSaltKey);
      if (storedHash == null || storedSalt == null) {
        _isUnlocked = true;
        _isConfigured = false;
        return true;
      }
      final computed = _hashPin(enteredPin, storedSalt);
      if (computed == storedHash) {
        _isUnlocked = true;
        return true;
      }
      return false;
    } catch (_) {
      return false;
    }
  }

  Future<void> setPin(String newPin) async {
    final salt = _randomSalt();
    final hash = _hashPin(newPin, salt);
    await _storage.write(key: _pinSaltKey, value: salt);
    await _storage.write(key: _pinHashKey, value: hash);
    _isConfigured = true;
    _isUnlocked = true;
  }

  Future<void> disable() async {
    await _storage.delete(key: _pinHashKey);
    await _storage.delete(key: _pinSaltKey);
    _isConfigured = false;
    _isUnlocked = true;
  }

  static String _randomSalt() {
    final rng = Random.secure();
    final bytes = Uint8List(16);
    for (var i = 0; i < 16; i++) {
      bytes[i] = rng.nextInt(256);
    }
    return base64Encode(bytes);
  }

  static String _hashPin(String pin, String salt) {
    final key = utf8.encode('$pin:$salt');
    final hmac = Hmac(sha256, key);
    return hmac.convert(utf8.encode('TEDRIVE_APP_LOCK_V1')).toString();
  }
}

/// A PIN entry screen shown when App Lock is active.
class AppLockScreen extends StatefulWidget {
  const AppLockScreen({
    super.key,
    required this.onSuccess,
    this.title = 'TeDrive is locked',
    this.subtitle = 'Enter your 4-digit PIN to continue',
  });

  final VoidCallback onSuccess;
  final String title;
  final String subtitle;

  @override
  State<AppLockScreen> createState() => _AppLockScreenState();
}

class _AppLockScreenState extends State<AppLockScreen> {
  String _pin = '';
  String? _error;
  bool _verifying = false;

  void _onDigit(String digit) {
    if (_pin.length >= 4 || _verifying) return;
    setState(() {
      _pin += digit;
      _error = null;
    });
    if (_pin.length == 4) {
      _verify();
    }
  }

  void _onBackspace() {
    if (_pin.isEmpty || _verifying) return;
    setState(() {
      _pin = _pin.substring(0, _pin.length - 1);
      _error = null;
    });
  }

  Future<void> _verify() async {
    setState(() => _verifying = true);
    final ok = await AppLockService.instance.verifyPin(_pin);
    if (!mounted) return;
    if (ok) {
      widget.onSuccess();
    } else {
      setState(() {
        _pin = '';
        _error = 'Incorrect PIN';
        _verifying = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 360),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const Spacer(flex: 2),
                Icon(Icons.lock_rounded, size: 56, color: scheme.primary),
                const SizedBox(height: 16),
                Text(
                  widget.title,
                  style: Theme.of(context).textTheme.titleLarge?.copyWith(
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  _error ?? widget.subtitle,
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: _error != null ? scheme.error : scheme.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: 24),
                // PIN dots
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    for (var i = 0; i < 4; i++)
                      Container(
                        margin: const EdgeInsets.symmetric(horizontal: 10),
                        width: 16,
                        height: 16,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: i < _pin.length
                              ? scheme.primary
                              : scheme.surfaceContainerHighest,
                          border: Border.all(
                            color: scheme.outline,
                            width: 1.5,
                          ),
                        ),
                      ),
                  ],
                ),
                const Spacer(flex: 1),
                // Number pad
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 24),
                  child: Column(
                    children: [
                      _padRow(['1', '2', '3']),
                      const SizedBox(height: 12),
                      _padRow(['4', '5', '6']),
                      const SizedBox(height: 12),
                      _padRow(['7', '8', '9']),
                      const SizedBox(height: 12),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                        children: [
                          const SizedBox(width: 72, height: 72),
                          _digitButton('0'),
                          SizedBox(
                            width: 72,
                            height: 72,
                            child: IconButton(
                              icon: const Icon(Icons.backspace_outlined),
                              onPressed: _onBackspace,
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
                const Spacer(flex: 2),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _padRow(List<String> digits) => Row(
    mainAxisAlignment: MainAxisAlignment.spaceEvenly,
    children: [for (final d in digits) _digitButton(d)],
  );

  Widget _digitButton(String digit) {
    final scheme = Theme.of(context).colorScheme;
    return SizedBox(
      width: 72,
      height: 72,
      child: OutlinedButton(
        style: OutlinedButton.styleFrom(
          shape: const CircleBorder(),
          padding: EdgeInsets.zero,
          side: BorderSide(color: scheme.outlineVariant),
        ),
        onPressed: () => _onDigit(digit),
        child: Text(
          digit,
          style: const TextStyle(fontSize: 24, fontWeight: FontWeight.w600),
        ),
      ),
    );
  }
}
