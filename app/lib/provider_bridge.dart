import 'dart:async';

import 'package:flutter/services.dart';

import 'device.dart' show isAndroid;
import 'tedrive_service.dart';

/// Answers Android's file picker when another app opens a TeDrive file
/// that is not on the phone yet: downloads it and replies with its path.
/// This works even when no TeDrive screen is showing.
void registerProviderBridge(TeDriveService service) {
  if (!isAndroid) return;
  const MethodChannel('tedrive/provider').setMethodCallHandler((call) async {
    if (call.method != 'download') throw MissingPluginException();
    final messageId = (call.arguments as Map)['id'] as int;
    await _whenSignedIn(service);
    final chatId = int.tryParse(await service.readSetting('channel_id') ?? '');
    if (chatId == null) throw StateError('TeDrive is not set up yet.');
    final file = await service.fetchFile(chatId, messageId);
    if (file == null) throw StateError('That file is no longer in the drive.');
    return service.download(file.fileId);
  });
}

/// Waits for the Telegram session to be ready, for up to 30 seconds.
Future<void> _whenSignedIn(TeDriveService service) async {
  if (service.authState.value == 'ready') return;
  final ready = Completer<void>();
  void check() {
    if (service.authState.value == 'ready' && !ready.isCompleted) {
      ready.complete();
    }
  }

  service.authState.addListener(check);
  try {
    await ready.future.timeout(const Duration(seconds: 30));
  } on TimeoutException {
    throw StateError('TeDrive is not signed in.');
  } finally {
    service.authState.removeListener(check);
  }
}
