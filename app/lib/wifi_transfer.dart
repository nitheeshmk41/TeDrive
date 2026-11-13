// Wi-Fi transfer: moves files between this device and any phone or computer
// on the same Wi-Fi, through a small web page served from this device. No
// internet is used.
//
// Safety: every request must carry the access code shown on this device,
// and only the files offered here can be fetched (by number, never by path).

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:archive/archive.dart' show getCrc32;

import 'wifi_transfer_page_html.dart';

/// A file offered to the other device.
typedef WifiFile = ({String name, int size, String path, String? thumb});

enum WifiDirection { sent, received }

/// One transfer, for the activity list.
class WifiActivity {
  WifiActivity(this.direction, this.name, this.total);
  final WifiDirection direction;
  final String name;
  final int total;
  int done = 0;
  bool finished = false;
  bool failed = false;

  /// Set for a received file once it is saved.
  File? file;
  double get progress => total <= 0 ? 0 : (done / total).clamp(0, 1);
}

class WifiTransferService {
  WifiTransferService._();
  static final WifiTransferService instance = WifiTransferService._();

  HttpServer? _server;
  String? _ip;
  String _code = '';
  String _deviceName = 'TeDrive';
  List<WifiFile> Function() _files = () => const [];
  Directory? _uploadDir;

  /// Newest first. Listen to [changes] to redraw.
  final List<WifiActivity> activity = [];
  final _changes = StreamController<void>.broadcast();
  final _received = StreamController<File>.broadcast();
  DateTime? lastSeen;

  bool get isRunning => _server != null;
  String get code => _code;
  Stream<void> get changes => _changes.stream;
  Stream<File> get onFileReceived => _received.stream;

  /// The address to open, including the access code (for the QR code).
  String? get url =>
      _server == null ? null : 'http://$_ip:${_server!.port}/?k=$_code';

  /// The address to type by hand; the page then asks for the code.
  String? get shortUrl =>
      _server == null ? null : 'http://$_ip:${_server!.port}';

  /// True if another device used the page in the last few seconds.
  bool get connected =>
      lastSeen != null &&
      DateTime.now().difference(lastSeen!) < const Duration(seconds: 8);

  static Future<String?> findLocalIp() async {
    try {
      final interfaces = await NetworkInterface.list(
        includeLoopback: false,
        type: InternetAddressType.IPv4,
      );
      String? fallback;
      for (final iface in interfaces) {
        for (final addr in iface.addresses) {
          final ip = addr.address;
          // Home Wi-Fi and hotspots use 192.168. Other private ranges are
          // also used by VPNs and mobile data, so they come second.
          if (ip.startsWith('192.168.')) return ip;
          if (ip.startsWith('10.') || ip.startsWith('172.')) fallback ??= ip;
        }
      }
      return fallback;
    } catch (_) {
      return null;
    }
  }

  /// Starts serving. Throws [StateError] when there is no Wi-Fi address.
  Future<void> start({
    required List<WifiFile> Function() files,
    required Directory uploadDir,
    required String deviceName,
  }) async {
    await stop();
    final ip = await findLocalIp();
    if (ip == null) {
      throw StateError(
        'Connect this device to Wi-Fi (or turn on its hotspot) first.',
      );
    }
    _ip = ip;
    _files = files;
    _uploadDir = uploadDir;
    _deviceName = deviceName;
    final rng = Random.secure();
    _code = List.generate(6, (_) => rng.nextInt(10)).join();
    activity.clear();
    lastSeen = null;

    HttpServer? server;
    for (var port = 8080; port < 8090 && server == null; port++) {
      try {
        server = await HttpServer.bind(InternetAddress.anyIPv4, port);
      } on SocketException {
        // Port in use: try the next one.
      }
    }
    server ??= await HttpServer.bind(InternetAddress.anyIPv4, 0);
    _server = server;
    server.listen(_handle, onError: (_) {});
  }

  Future<void> stop() async {
    final server = _server;
    _server = null;
    await server?.close(force: true);
    _changed();
  }

  void _changed() {
    if (!_changes.isClosed) _changes.add(null);
  }

  Future<void> _handle(HttpRequest request) async {
    final response = request.response;
    try {
      final path = request.uri.path;
      final params = request.uri.queryParameters;
      response.headers
        ..set('Cache-Control', 'no-store')
        ..set('X-Content-Type-Options', 'nosniff');
      if (path == '/' && request.method == 'GET') {
        response.headers.contentType = ContentType.html;
        response.write(wifiTransferPageHtml);
        return await response.close();
      }
      if (params['k'] != _code) {
        response.statusCode = HttpStatus.forbidden;
        response.write('Wrong access code');
        return await response.close();
      }
      lastSeen = DateTime.now();
      final files = _files();
      if (path == '/api/info') {
        return await _json(response, {
          'device': _deviceName,
          'files': [
            for (var i = 0; i < files.length; i++)
              {
                'id': i,
                'name': files[i].name,
                'size': files[i].size,
                'thumb': files[i].thumb != null,
              },
          ],
        });
      }
      if (path == '/api/ping') {
        _changed();
        return await _json(response, {'ok': true});
      }
      if (path == '/file' || path == '/thumb') {
        final id = int.tryParse(params['id'] ?? '');
        if (id == null || id < 0 || id >= files.length) {
          response.statusCode = HttpStatus.notFound;
          return await response.close();
        }
        if (path == '/thumb') {
          final thumb = files[id].thumb;
          if (thumb == null || !File(thumb).existsSync()) {
            response.statusCode = HttpStatus.notFound;
            return await response.close();
          }
          response.headers.contentType = ContentType('image', 'jpeg');
          response.headers.set('Cache-Control', 'private, max-age=3600');
          return await response
              .addStream(File(thumb).openRead())
              .then((_) => response.close());
        }
        return await _sendFile(request, files[id], params['view'] == '1');
      }
      if (path == '/zip') {
        final ids = (params['ids'] ?? '')
            .split(',')
            .map(int.tryParse)
            .whereType<int>()
            .where((i) => i >= 0 && i < files.length)
            .toSet();
        if (ids.isEmpty) {
          response.statusCode = HttpStatus.badRequest;
          return await response.close();
        }
        return await _sendZip(response, [for (final i in ids) files[i]]);
      }
      if (path == '/upload' && request.method == 'POST') {
        return await _receive(request, params['name'] ?? '');
      }
      response.statusCode = HttpStatus.notFound;
      await response.close();
    } catch (_) {
      try {
        await response.close();
      } catch (_) {}
    }
  }

  Future<void> _json(HttpResponse response, Object body) async {
    response.headers.contentType = ContentType.json;
    response.write(jsonEncode(body));
    await response.close();
  }

  static String _disposition(String name, {bool inline = false}) {
    final ascii = name.replaceAll(RegExp(r'[^\x20-\x7E]|["\\]'), '_');
    return '${inline ? 'inline' : 'attachment'}; filename="$ascii"; '
        "filename*=UTF-8''${Uri.encodeComponent(name)}";
  }

  static ContentType _typeOf(String name) {
    final ext = name.contains('.') ? name.split('.').last.toLowerCase() : '';
    return switch (ext) {
      'jpg' || 'jpeg' => ContentType('image', 'jpeg'),
      'png' => ContentType('image', 'png'),
      'gif' => ContentType('image', 'gif'),
      'webp' => ContentType('image', 'webp'),
      'mp4' || 'm4v' => ContentType('video', 'mp4'),
      'webm' => ContentType('video', 'webm'),
      'mp3' => ContentType('audio', 'mpeg'),
      'pdf' => ContentType('application', 'pdf'),
      _ => ContentType.binary,
    };
  }

  /// Sends one file, with resume (Range) support.
  Future<void> _sendFile(HttpRequest request, WifiFile f, bool view) async {
    final response = request.response;
    final file = File(f.path);
    if (!file.existsSync()) {
      response.statusCode = HttpStatus.notFound;
      return response.close();
    }
    final length = file.lengthSync();
    var start = 0;
    var end = length - 1;
    final range = RegExp(r'^bytes=(\d*)-(\d*)$')
        .firstMatch(request.headers.value('range') ?? '');
    if (range != null && length > 0) {
      final a = int.tryParse(range.group(1)!);
      final b = int.tryParse(range.group(2)!);
      if (a != null) {
        start = a;
        if (b != null) end = min(b, length - 1);
      } else if (b != null) {
        start = max(0, length - b);
      }
      if (start > end) {
        response.statusCode = HttpStatus.requestedRangeNotSatisfiable;
        return response.close();
      }
      response.statusCode = HttpStatus.partialContent;
      response.headers.set('Content-Range', 'bytes $start-$end/$length');
    }
    response.headers
      ..contentType = view ? _typeOf(f.name) : ContentType.binary
      ..set('Accept-Ranges', 'bytes')
      ..set('Content-Disposition', _disposition(f.name, inline: view))
      ..contentLength = length == 0 ? 0 : end - start + 1;
    // Previews and resumed pieces are not listed as transfers.
    final entry = view || range != null
        ? null
        : WifiActivity(WifiDirection.sent, f.name, length);
    if (entry != null) {
      activity.insert(0, entry);
      _changed();
    }
    try {
      var lastShown = DateTime.now();
      await response.addStream(
        file.openRead(start, end + 1).map((chunk) {
          if (entry != null) {
            entry.done += chunk.length;
            final now = DateTime.now();
            if (now.difference(lastShown).inMilliseconds > 250) {
              lastShown = now;
              lastSeen = now;
              _changed();
            }
          }
          return chunk;
        }),
      );
      await response.close();
      entry?.finished = true;
    } catch (_) {
      entry?.failed = true;
    }
    _changed();
  }

  /// Streams the files as one .zip (stored, not compressed: photos and
  /// videos do not shrink, and this keeps the phone cool).
  Future<void> _sendZip(HttpResponse response, List<WifiFile> files) async {
    response.headers
      ..contentType = ContentType('application', 'zip')
      ..set('Content-Disposition', _disposition('TeDrive files.zip'));
    final total = files.fold<int>(0, (sum, f) => sum + f.size);
    final entry = WifiActivity(
      WifiDirection.sent,
      '${files.length} files (zip)',
      total,
    );
    activity.insert(0, entry);
    _changed();
    try {
      final central = BytesBuilder();
      var offset = 0;
      var count = 0;
      final used = <String>{};
      var lastShown = DateTime.now();
      for (final f in files) {
        final file = File(f.path);
        // Zip without the 64-bit extension holds files below 4 GB.
        if (!file.existsSync() || file.lengthSync() >= 0xFFFFFFFF) continue;
        var name = f.name.replaceAll(RegExp(r'[\\/]'), '_');
        for (var n = 2; !used.add(name.toLowerCase()); n++) {
          name = '($n) ${f.name.replaceAll(RegExp(r'[\\/]'), '_')}';
        }
        final nameBytes = utf8.encode(name);
        final header = ByteData(30)
          ..setUint32(0, 0x04034b50, Endian.little)
          ..setUint16(4, 20, Endian.little)
          // Bit 3: sizes follow the data. Bit 11: the name is UTF-8.
          ..setUint16(6, 0x0808, Endian.little)
          ..setUint16(26, nameBytes.length, Endian.little);
        response.add(header.buffer.asUint8List());
        response.add(nameBytes);
        var crc = 0;
        var size = 0;
        await response.addStream(
          file.openRead().map((chunk) {
            crc = getCrc32(chunk, crc);
            size += chunk.length;
            entry.done += chunk.length;
            final now = DateTime.now();
            if (now.difference(lastShown).inMilliseconds > 250) {
              lastShown = now;
              lastSeen = now;
              _changed();
            }
            return chunk;
          }),
        );
        final descriptor = ByteData(16)
          ..setUint32(0, 0x08074b50, Endian.little)
          ..setUint32(4, crc, Endian.little)
          ..setUint32(8, size, Endian.little)
          ..setUint32(12, size, Endian.little);
        response.add(descriptor.buffer.asUint8List());
        final dir = ByteData(46)
          ..setUint32(0, 0x02014b50, Endian.little)
          ..setUint16(4, 20, Endian.little)
          ..setUint16(6, 20, Endian.little)
          ..setUint16(8, 0x0808, Endian.little)
          ..setUint32(16, crc, Endian.little)
          ..setUint32(20, size, Endian.little)
          ..setUint32(24, size, Endian.little)
          ..setUint16(28, nameBytes.length, Endian.little)
          ..setUint32(42, offset, Endian.little);
        central
          ..add(dir.buffer.asUint8List())
          ..add(nameBytes);
        offset += 30 + nameBytes.length + size + 16;
        count++;
      }
      final centralBytes = central.takeBytes();
      final end = ByteData(22)
        ..setUint32(0, 0x06054b50, Endian.little)
        ..setUint16(8, count, Endian.little)
        ..setUint16(10, count, Endian.little)
        ..setUint32(12, centralBytes.length, Endian.little)
        ..setUint32(16, offset, Endian.little);
      response.add(centralBytes);
      response.add(end.buffer.asUint8List());
      await response.close();
      entry.finished = true;
    } catch (_) {
      entry.failed = true;
    }
    _changed();
  }

  /// Saves an uploaded file. The body is the file itself, written to disk
  /// as it arrives, so large files do not fill the memory.
  Future<void> _receive(HttpRequest request, String rawName) async {
    final response = request.response;
    final dir = _uploadDir!..createSync(recursive: true);
    var name = rawName
        .replaceAll(RegExp(r'[\\/:*?"<>|\x00-\x1F]'), '_')
        .replaceAll(RegExp(r'^\.+'), '_')
        .trim();
    if (name.isEmpty) name = 'file_${DateTime.now().millisecondsSinceEpoch}';
    if (name.length > 180) name = name.substring(name.length - 180);
    var target = File('${dir.path}${Platform.pathSeparator}$name');
    for (var n = 2; target.existsSync(); n++) {
      target = File('${dir.path}${Platform.pathSeparator}($n) $name');
    }
    final entry = WifiActivity(
      WifiDirection.received,
      name,
      request.contentLength,
    );
    activity.insert(0, entry);
    _changed();
    final sink = target.openWrite();
    try {
      var lastShown = DateTime.now();
      await for (final chunk in request) {
        sink.add(chunk);
        entry.done += chunk.length;
        final now = DateTime.now();
        if (now.difference(lastShown).inMilliseconds > 250) {
          lastShown = now;
          lastSeen = now;
          await sink.flush();
          _changed();
        }
      }
      await sink.close();
      entry
        ..finished = true
        ..file = target;
      _received.add(target);
      await _json(response, {'ok': true});
    } catch (_) {
      entry.failed = true;
      try {
        await sink.close();
        if (target.existsSync()) target.deleteSync();
      } catch (_) {}
      response.statusCode = HttpStatus.internalServerError;
      await response.close();
    }
    _changed();
  }
}
