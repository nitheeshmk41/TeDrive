import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'backup_plan.dart';

bool get _isAndroid => !kIsWeb && Platform.isAndroid;

/// Android-side helpers: the phone's media library, connection and power
/// state, and the service that keeps uploads alive in the background.
const _channel = MethodChannel('tedrive/device');

/// "full", "partial" (only photos the user selected) or "none".
Future<String> mediaPermission() async {
  if (!_isAndroid) return 'none';
  return await _channel.invokeMethod<String>('hasMediaPermission') ?? 'none';
}

Future<String> requestMediaPermission() async {
  if (!_isAndroid) return 'none';
  return await _channel.invokeMethod<String>('requestMediaPermission') ?? 'none';
}

Future<List<MediaItem>> listMedia() async {
  if (!_isAndroid) return const [];
  final raw = await _channel.invokeListMethod<Map<Object?, Object?>>(
    'listMedia',
  );
  return [for (final m in raw ?? const []) MediaItem.fromMap(m)];
}

/// Asks Android to delete [items] from the phone. Android 11+ shows its
/// own confirmation first. Returns how many were deleted.
Future<int> deleteMedia(List<MediaItem> items) async {
  if (!_isAndroid) return 0;
  var deleted = 0;
  // Keep each request comfortably inside Android's message size limit.
  for (var i = 0; i < items.length; i += 1500) {
    final chunk = items.skip(i).take(1500);
    deleted +=
        await _channel.invokeMethod<int>('deleteMedia', {
          'items': [
            for (final m in chunk) {'id': m.id, 'video': m.video},
          ],
        }) ??
        0;
  }
  return deleted;
}

typedef DeviceStatus = ({bool online, bool unmetered, bool charging});

Future<DeviceStatus> deviceStatus() async {
  if (!_isAndroid) {
    return (online: true, unmetered: true, charging: true);
  }
  final m = await _channel.invokeMapMethod<String, bool>('deviceStatus');
  return (
    online: m?['online'] ?? true,
    unmetered: m?['unmetered'] ?? true,
    charging: m?['charging'] ?? true,
  );
}

/// Starts the background service. False if Android refused, which happens
/// when the app is not on screen at that moment.
Future<bool> startKeepAlive(String text, {int progress = -1}) async {
  if (!_isAndroid) return false;
  try {
    return await _channel.invokeMethod<bool>('startService', {
          'title': 'TeDrive',
          'text': text,
          'progress': progress,
        }) ??
        false;
  } on PlatformException {
    return false;
  }
}

Future<void> updateKeepAlive(String text, {int progress = -1}) {
  if (!_isAndroid) return Future.value();
  return _channel.invokeMethod<void>('updateService', {
    'title': 'TeDrive',
    'text': text,
    'progress': progress,
  });
}

Future<void> stopKeepAlive() {
  if (!_isAndroid) return Future.value();
  return _channel.invokeMethod<void>('stopService');
}

Future<void> requestNotificationPermission() {
  if (!_isAndroid) return Future.value();
  return _channel.invokeMethod<void>('requestNotificationPermission');
}
