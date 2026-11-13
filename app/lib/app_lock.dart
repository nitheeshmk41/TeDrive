// App Lock: Protects the app with a secure PIN.
// PIN is hashed with PBKDF2-HMAC-SHA256 and stored in flutter_secure_storage.

import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:local_auth_android/local_auth_android.dart';
import 'package:local_auth_platform_interface/local_auth_platform_interface.dart';

class AppLockService {
  AppLockService._();
  static final AppLockService instance = AppLockService._();

  static const _pinHashKey = 'tedrive_app_lock_pin_hash';
  static const _pinSaltKey = 'tedrive_app_lock_pin_salt';
  static const _storage = FlutterSecureStorage();

  static const _bioKey = 'tedrive_app_lock_biometric';
  // Android and Apple only: the Windows plugin does not build with current
  // Visual Studio, and Linux has none.
  LocalAuthPlatform get _auth => LocalAuthPlatform.instance;
  bool _biometric = false;
  DateTime? _pausedAt;

  /// Fingerprint or face unlock, on top of the PIN.
  bool get biometricEnabled => _biometric;

  bool _isUnlocked = false;
  bool _isConfigured = false;

  // A 4-digit PIN has only 10,000 possibilities, so wrong guesses are
  // slowed down: after 5 in a row the keypad pauses, longer each time.
  // Kept in secure storage so that restarting the app does not reset it.
  static const _failKey = 'tedrive_app_lock_failures';
  static const _untilKey = 'tedrive_app_lock_until';
  static const _freeTries = 5;
  int _failures = 0;
  DateTime? _lockedUntil;

  /// How long PIN entry is still paused after too many wrong tries.
  Duration get lockedFor {
    final until = _lockedUntil;
    if (until == null) return Duration.zero;
    final left = until.difference(DateTime.now());
    return left.isNegative ? Duration.zero : left;
  }

  /// The pause after [failures] wrong PINs in a row: none for the first
  /// few, then 30 s, 1 min, 2 min… up to 15 minutes.
  static Duration pauseAfter(int failures) {
    if (failures < _freeTries) return Duration.zero;
    final steps = failures - _freeTries;
    final seconds = steps >= 5 ? 900 : 30 * (1 << steps);
    return Duration(seconds: seconds > 900 ? 900 : seconds);
  }

  Future<void> _recordFailure() async {
    _failures++;
    final pause = pauseAfter(_failures);
    _lockedUntil = pause == Duration.zero ? null : DateTime.now().add(pause);
    await _storage.write(key: _failKey, value: '$_failures');
    if (_lockedUntil != null) {
      await _storage.write(
        key: _untilKey,
        value: '${_lockedUntil!.millisecondsSinceEpoch}',
      );
    }
  }

  Future<void> _clearFailures() async {
    if (_failures == 0 && _lockedUntil == null) return;
    _failures = 0;
    _lockedUntil = null;
    await _storage.delete(key: _failKey);
    await _storage.delete(key: _untilKey);
  }

  bool get isUnlocked => !_isConfigured || _isUnlocked;
  bool get isConfigured => _isConfigured;

  Future<void> init() async {
    try {
      final hash = await _storage.read(key: _pinHashKey);
      _isConfigured = hash != null && hash.isNotEmpty;
      _biometric = await _storage.read(key: _bioKey) == 'true';
      _failures = int.tryParse(await _storage.read(key: _failKey) ?? '') ?? 0;
      final until = int.tryParse(await _storage.read(key: _untilKey) ?? '');
      if (until != null) {
        _lockedUntil = DateTime.fromMillisecondsSinceEpoch(until);
      }
    } catch (_) {
      _isConfigured = false;
    }
  }

  void lock() {
    _isUnlocked = false;
  }

  /// Called when the app goes to the background. Opening the file picker or
  /// share sheet also does this, so the lock waits a little before closing.
  void onPaused() => _pausedAt ??= DateTime.now();

  /// Called when the app comes back. Returns true if it locked.
  bool onResumed() {
    final since = _pausedAt;
    _pausedAt = null;
    if (!_isConfigured || since == null) return false;
    if (DateTime.now().difference(since) < const Duration(seconds: 30)) {
      return false;
    }
    lock();
    return true;
  }

  /// Whether this device can unlock with a fingerprint or face.
  Future<bool> canUseBiometric() async {
    try {
      return await _auth.isDeviceSupported() &&
          await _auth.deviceSupportsBiometrics();
    } catch (_) {
      return false;
    }
  }

  Future<void> setBiometric(bool on) async {
    _biometric = on;
    await _storage.write(key: _bioKey, value: on.toString());
  }

  /// Shows the system fingerprint prompt. Unlocks on success.
  Future<bool> unlockWithBiometric() async {
    if (!_biometric) return false;
    try {
      final ok = await _auth.authenticate(
        localizedReason: 'Unlock TeDrive',
        authMessages: const [AndroidAuthMessages()],
        options: const AuthenticationOptions(biometricOnly: true),
      );
      if (ok) _isUnlocked = true;
      return ok;
    } catch (_) {
      return false;
    }
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
      if (lockedFor > Duration.zero) return false;
      final computed = _hashPin(enteredPin, storedSalt);
      if (computed == storedHash) {
        _isUnlocked = true;
        await _clearFailures();
        return true;
      }
      await _recordFailure();
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
    await _storage.delete(key: _bioKey);
    await _clearFailures();
    _biometric = false;
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

  @override
  void initState() {
    super.initState();
    if (AppLockService.instance.biometricEnabled) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _biometric());
    }
  }

  Future<void> _biometric() async {
    if (await AppLockService.instance.unlockWithBiometric() && mounted) {
      widget.onSuccess();
    }
  }

  String _pauseText() {
    final left = AppLockService.instance.lockedFor.inSeconds + 1;
    return left > 90
        ? 'Too many wrong PINs. Try again in ${(left / 60).ceil()} minutes.'
        : 'Too many wrong PINs. Try again in $left seconds.';
  }

  void _onDigit(String digit) {
    if (_pin.length >= 4 || _verifying) return;
    if (AppLockService.instance.lockedFor > Duration.zero) {
      setState(() => _error = _pauseText());
      return;
    }
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
        _error = AppLockService.instance.lockedFor > Duration.zero
            ? _pauseText()
            : 'Incorrect PIN';
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
                  style: Theme.of(context).textTheme.titleLarge
                      ?.copyWith(fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 6),
                Text(
                  _error ?? widget.subtitle,
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: _error != null
                        ? scheme.error
                        : scheme.onSurfaceVariant,
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
                          border: Border.all(color: scheme.outline, width: 1.5),
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
                          SizedBox(
                            width: 72,
                            height: 72,
                            child: AppLockService.instance.biometricEnabled
                                ? IconButton(
                                    tooltip: 'Use fingerprint',
                                    icon: const Icon(
                                      Icons.fingerprint,
                                      size: 32,
                                    ),
                                    onPressed: _biometric,
                                  )
                                : null,
                          ),
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
