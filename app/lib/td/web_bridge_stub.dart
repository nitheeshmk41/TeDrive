// Stand-in for web_bridge_js.dart on platforms that are not the web. None of
// it is ever called there; it only lets the shared code compile.

abstract final class WebTd {
  static bool get available => false;

  static void create(void Function(String json) onUpdate) =>
      throw UnsupportedError('web only');

  static Future<String> send(String json) => throw UnsupportedError('web only');

  static Future<int> putBlob(String url) => throw UnsupportedError('web only');

  static void releaseBlob(int id) => throw UnsupportedError('web only');

  static Future<String?> fileUrl(int fileId, {String? mime}) =>
      throw UnsupportedError('web only');

  static void save(String url, String name) =>
      throw UnsupportedError('web only');

  static void open(String url) => throw UnsupportedError('web only');
}

String browserDescription() => 'Browser';
