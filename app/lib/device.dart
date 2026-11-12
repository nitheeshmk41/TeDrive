import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'backup_plan.dart';
import 'td/web_bridge.dart';

/// Platform helpers. On Android these call into the app's native side: the
/// media library, connection and power state, sharing, and the service
/// that keeps uploads alive in the background. Elsewhere they fall back to
/// harmless defaults.
const _channel = MethodChannel('tedrive/device');

bool get isAndroid => !kIsWeb && Platform.isAndroid;

/// Windows, Linux or macOS.
bool get isDesktop =>
    !kIsWeb && (Platform.isWindows || Platform.isLinux || Platform.isMacOS);

/// Whether the in-app video and audio player works on this platform.
bool get hasBuiltInPlayer =>
    kIsWeb || Platform.isAndroid || Platform.isIOS || Platform.isMacOS;

/// A file another app shared into TeDrive.
typedef SharedFile = ({
  String path,
  String name,
  int size,
  DateTime? taken,

  /// True for a private copy that should be deleted after upload.
  bool temporary,
});

/// Takes the files other apps have shared into TeDrive since the last call.
Future<List<SharedFile>> takeSharedFiles() async {
  if (!isAndroid) return const [];
  final raw = await _channel.invokeListMethod<Map<Object?, Object?>>(
    'takeSharedFiles',
  );
  return [
    for (final m in raw ?? const <Map<Object?, Object?>>[])
      (
        path: m['path'] as String,
        name: m['name'] as String,
        size: m['size'] as int,
        taken: (m['time'] as int? ?? 0) > 0
            ? DateTime.fromMillisecondsSinceEpoch((m['time'] as int) * 1000)
            : null,
        temporary: m['temp'] == true,
      ),
  ];
}

/// Calls [listener] whenever new shared files arrive while the app is
/// running. Pass null to stop.
void onSharedFiles(void Function()? listener) {
  if (!isAndroid) return;
  _channel.setMethodCallHandler(
    listener == null
        ? null
        : (call) async {
            if (call.method == 'sharedFilesReady') listener();
          },
  );
}

/// A readable name for this device, e.g. "Samsung SM-A525F".
Future<String> deviceName() async {
  if (kIsWeb) return browserDescription();
  if (isAndroid) {
    try {
      final name = await _channel.invokeMethod<String>('deviceName');
      if (name != null && name.isNotEmpty) return name;
    } on PlatformException {
      // Fall through to the generic name.
    }
    return 'Android phone';
  }
  final host = Platform.localHostname;
  final os = Platform.isWindows
      ? 'Windows'
      : Platform.isLinux
      ? 'Linux'
      : Platform.isMacOS
      ? 'Mac'
      : 'Computer';
  return host.isEmpty ? '$os computer' : '$host ($os)';
}

/// Opens Android's share sheet for a file, with its real MIME type so that
/// apps such as WhatsApp accept it. Returns false where this is not
/// available, so the caller can fall back.
Future<bool> shareFile(
  String path, {
  required String mime,
  String? name,
}) async {
  if (!isAndroid) return false;
  await _channel.invokeMethod<void>('share', {
    'path': path,
    'mime': mime,
    'name': name,
  });
  return true;
}

/// Opens a file in whichever installed app handles its type.
/// Returns false if no app can open it.
Future<bool> openFile(String path, {required String mime, String? name}) async {
  if (kIsWeb) {
    // A blob: URL opens in a new tab: the browser shows photos, videos,
    // audio and PDFs, and downloads anything else.
    WebTd.open(path);
    return true;
  }
  if (!isAndroid) return false;
  return await _channel.invokeMethod<bool>('open', {
        'path': path,
        'mime': mime,
        'name': name,
      }) ??
      false;
}

/// "full", "partial" (only photos the user selected) or "none".
Future<String> mediaPermission() async {
  if (!isAndroid) return 'none';
  return await _channel.invokeMethod<String>('hasMediaPermission') ?? 'none';
}

Future<String> requestMediaPermission() async {
  if (!isAndroid) return 'none';
  return await _channel.invokeMethod<String>('requestMediaPermission') ??
      'none';
}

Future<List<MediaItem>> listMedia() async {
  if (!isAndroid) return const [];
  final raw = await _channel.invokeListMethod<Map<Object?, Object?>>(
    'listMedia',
  );
  return [for (final m in raw ?? const []) MediaItem.fromMap(m)];
}

/// Asks Android to delete [items] from the phone. Android 11+ shows its
/// own confirmation first. Returns how many were deleted.
Future<int> deleteMedia(List<MediaItem> items) async {
  if (!isAndroid) return 0;
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
  if (!isAndroid) return (online: true, unmetered: true, charging: true);
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
  if (!isAndroid) return false;
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

Future<void> updateKeepAlive(String text, {int progress = -1}) async {
  if (!isAndroid) return;
  await _channel.invokeMethod<void>('updateService', {
    'title': 'TeDrive',
    'text': text,
    'progress': progress,
  });
}

Future<void> stopKeepAlive() async {
  if (!isAndroid) return;
  await _channel.invokeMethod<void>('stopService');
}

Future<void> requestNotificationPermission() async {
  if (!isAndroid) return;
  await _channel.invokeMethod<void>('requestNotificationPermission');
}
