// The web side of TeDrive's Telegram connection: calls into
// web/tedrive_td.js, which drives tdweb (TDLib compiled to WebAssembly).
import 'dart:js_interop';

import 'package:web/web.dart' as web;

@JS('tedriveTd')
external _Bridge? get _bridge;

extension type _Bridge(JSObject _) implements JSObject {
  external bool available();
  external void create(JSFunction onUpdate);
  external JSPromise<JSString> send(String json);
  external JSPromise<JSNumber> putBlobFromUrl(String url);
  external void releaseBlob(int id);
  external JSPromise<JSString?> readFileUrl(int fileId, String? mime);
  external void saveUrl(String url, String name);
  external void openUrl(String url);
}

/// TDLib running inside the browser.
abstract final class WebTd {
  /// Whether tdweb.js loaded.
  static bool get available {
    try {
      return _bridge?.available() ?? false;
    } catch (_) {
      return false;
    }
  }

  /// Starts TDLib; [onUpdate] receives every update as JSON.
  static void create(void Function(String json) onUpdate) {
    _bridge!.create(((JSString json) => onUpdate(json.toDart)).toJS);
  }

  /// Sends a request; completes with the reply (or an error object) as JSON.
  static Future<String> send(String json) async =>
      (await _bridge!.send(json).toDart).toDart;

  /// Registers a browser file (blob: URL) for upload. Returns its number.
  static Future<int> putBlob(String url) async =>
      (await _bridge!.putBlobFromUrl(url).toDart).toDartInt;

  static void releaseBlob(int id) => _bridge!.releaseBlob(id);

  /// A blob: URL for a downloaded file, or null if it is not downloaded.
  static Future<String?> fileUrl(int fileId, {String? mime}) async =>
      (await _bridge!.readFileUrl(fileId, mime).toDart)?.toDart;

  static void save(String url, String name) => _bridge!.saveUrl(url, name);

  static void open(String url) => _bridge!.openUrl(url);
}

/// "Chrome on Windows", "Safari on iPhone" and so on.
String browserDescription() {
  final ua = web.window.navigator.userAgent;
  final browser = ua.contains('Edg/')
      ? 'Edge'
      : ua.contains('OPR/') || ua.contains('Opera')
      ? 'Opera'
      : ua.contains('Firefox/')
      ? 'Firefox'
      : ua.contains('Chrome/') || ua.contains('CriOS/')
      ? 'Chrome'
      : ua.contains('Safari/')
      ? 'Safari'
      : 'Browser';
  final os = ua.contains('iPhone')
      ? 'iPhone'
      : ua.contains('iPad')
      ? 'iPad'
      : ua.contains('Android')
      ? 'Android'
      : ua.contains('Windows')
      ? 'Windows'
      : ua.contains('Mac OS')
      ? 'Mac'
      : ua.contains('CrOS')
      ? 'Chromebook'
      : ua.contains('Linux')
      ? 'Linux'
      : 'the web';
  return '$browser on $os';
}
