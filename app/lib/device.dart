import 'dart:io' show Platform, Process;

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
  _sharedListener = listener;
  _installHandler();
}

/// Calls [listener] when a widget button, reminder notification or the
/// backup alarm asks the running app to do something ("backup",
/// "scheduledBackup"). Pass null to stop.
void onLaunchAction(void Function(String action)? listener) {
  _actionListener = listener;
  _installHandler();
}

void Function()? _sharedListener;
void Function(String action)? _actionListener;

void _installHandler() {
  if (!isAndroid) return;
  final none = _sharedListener == null && _actionListener == null;
  _channel.setMethodCallHandler(
    none
        ? null
        : (call) async {
            if (call.method == 'sharedFilesReady') _sharedListener?.call();
            if (call.method == 'launchAction' && call.arguments is String) {
              _actionListener?.call(call.arguments as String);
            }
          },
  );
}

/// The action the app was opened for (from the widget or a notification),
/// once.
Future<String?> takeLaunchAction() async {
  if (!isAndroid) return null;
  try {
    return await _channel.invokeMethod<String>('takeLaunchAction');
  } on PlatformException {
    return null;
  }
}

/// Labels ("Beach", "Food"…), printed text and the number of faces found in
/// a photo, worked out
/// on the phone. Null where this is not available or the image is unreadable.
Future<({List<String> labels, String text, int faces})?> analyzeImage(
  String path,
) async {
  if (!isAndroid) return null;
  try {
    final m = await _channel.invokeMapMethod<String, Object?>('analyzeImage', {
      'path': path,
    });
    if (m == null) return null;
    return (
      labels: (m['labels'] as List? ?? const []).whereType<String>().toList(),
      text: m['text'] as String? ?? '',
      faces: m['faces'] as int? ?? 0,
    );
  } on PlatformException {
    return null;
  } on MissingPluginException {
    return null;
  }
}

/// Copies a file into Downloads/[folder] on the phone. Returns where it went.
Future<String?> saveToDownloads(
  String path, {
  required String name,
  required String mime,
  String folder = 'TeDrive',
}) async {
  if (!isAndroid) return null;
  return _channel.invokeMethod<String>('saveToDownloads', {
    'path': path,
    'name': name,
    'mime': mime,
    'folder': folder,
  });
}

/// Updates the home-screen widgets (status, detail, progress, size, count,
/// files, media, waiting).
Future<void> updateWidget(Map<String, Object> values) async {
  if (!isAndroid) return;
  try {
    await _channel.invokeMethod<void>('updateWidget', values);
  } on PlatformException {
    // The widget is a nicety.
  }
}

/// Sets the Android alarm for daily or weekly backup ([mode] "off",
/// "instant", "daily" or "weekly").
Future<void> setBackupSchedule({
  required String mode,
  required Iterable<String> albums,
  required DateTime? lastRun,
}) async {
  if (!isAndroid) return;
  try {
    await _channel.invokeMethod<void>('setBackupSchedule', {
      'mode': mode,
      'albums': albums.toList(),
      'lastRun': (lastRun?.millisecondsSinceEpoch ?? 0) ~/ 1000,
    });
  } on PlatformException {
    // Backup still runs whenever the app is open.
  }
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

/// Opens a link (for example tg://…) in the app that handles it.
/// Returns false if no app does.
Future<bool> openLink(String url) async {
  try {
    if (kIsWeb) {
      WebTd.open(url);
      return true;
    }
    if (isAndroid) {
      return await _channel.invokeMethod<bool>('openUrl', {'url': url}) ??
          false;
    }
    final result = Platform.isWindows
        ? await Process.run('rundll32', ['url.dll,FileProtocolHandler', url])
        : await Process.run(Platform.isMacOS ? 'open' : 'xdg-open', [url]);
    return result.exitCode == 0;
  } catch (_) {
    return false;
  }
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

/// Whether the APK at [path] is signed with the same key as the installed
/// TeDrive, so Android will install it as an update. Null if unknown.
Future<bool?> apkMatchesInstalled(String path) async {
  if (!isAndroid) return null;
  try {
    return await _channel.invokeMethod<bool>('apkMatchesInstalled', {
      'path': path,
    });
  } on PlatformException {
    return null;
  }
}

/// Opens Android's "Uninstall TeDrive?" screen.
Future<bool> uninstallSelf() async {
  if (!isAndroid) return false;
  try {
    return await _channel.invokeMethod<bool>('uninstallSelf') ?? false;
  } on PlatformException {
    return false;
  }
}
