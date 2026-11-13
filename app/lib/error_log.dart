// A small on-device log of errors, so a problem seen on a phone can be
// copied and reported. Nothing is ever sent anywhere by the app.

import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

const _maxBytes = 200 * 1024;
File? _file;

Future<File?> _logFile() async {
  if (kIsWeb) return null;
  try {
    return _file ??= File(
      '${(await getApplicationSupportDirectory()).path}/errors.log',
    );
  } catch (_) {
    return null;
  }
}

/// Records [error] under a short [where] label. Never throws.
Future<void> logError(String where, Object error, [StackTrace? stack]) async {
  debugPrint('[$where] $error');
  final file = await _logFile();
  if (file == null) return;
  try {
    if (file.existsSync() && file.lengthSync() > _maxBytes) {
      // Keep the newer half.
      final text = file.readAsStringSync();
      file.writeAsStringSync(text.substring(text.length ~/ 2));
    }
    final trace = stack == null
        ? ''
        : '\n${stack.toString().split('\n').take(8).join('\n')}';
    file.writeAsStringSync(
      '${DateTime.now().toIso8601String()} [$where] $error$trace\n',
      mode: FileMode.append,
    );
  } catch (_) {}
}

/// The log text, or an empty string if there is none.
Future<String> readErrorLog() async {
  final file = await _logFile();
  try {
    return file != null && file.existsSync() ? file.readAsStringSync() : '';
  } catch (_) {
    return '';
  }
}

/// Sends uncaught errors to the log.
void installErrorLog() {
  final previous = FlutterError.onError;
  FlutterError.onError = (details) {
    logError('ui', details.exception, details.stack);
    previous?.call(details);
  };
  PlatformDispatcher.instance.onError = (error, stack) {
    logError('uncaught', error, stack);
    return true;
  };
}
