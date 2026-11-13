// Wi-Fi Transfer: Phone-to-laptop direct transfer over local Wi-Fi without
// burning internet data or uploading to Telegram.
//
// Starts a lightweight local HTTP server on the phone and serves a responsive
// web portal for laptops/computers on the same Wi-Fi network.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

class WifiTransferService {
  WifiTransferService._();
  static final WifiTransferService instance = WifiTransferService._();

  HttpServer? _server;
  String? _ipAddress;
  int _port = 8080;
  final List<File> _receivedFiles = [];
  final StreamController<File> _onFileReceived =
      StreamController<File>.broadcast();

  bool get isRunning => _server != null;
  String? get ipAddress => _ipAddress;
  int get port => _port;
  String? get serverUrl =>
      _ipAddress != null ? 'http://$_ipAddress:$_port' : null;
  Stream<File> get onFileReceived => _onFileReceived.stream;
  List<File> get receivedFiles => List.unmodifiable(_receivedFiles);

  Future<String?> findLocalIp() async {
    try {
      final interfaces = await NetworkInterface.list(
        includeLoopback: false,
        type: InternetAddressType.IPv4,
      );
      for (final iface in interfaces) {
        for (final addr in iface.addresses) {
          if (!addr.isLoopback && addr.type == InternetAddressType.IPv4) {
            final ip = addr.address;
            if (ip.startsWith('192.168.') ||
                ip.startsWith('10.') ||
                ip.startsWith('172.')) {
              return ip;
            }
          }
        }
      }
      if (interfaces.isNotEmpty && interfaces.first.addresses.isNotEmpty) {
        return interfaces.first.addresses.first.address;
      }
    } catch (_) {}
    return '127.0.0.1';
  }

  Future<String> startServer({
    required List<({String name, int size, String path})> shareableFiles,
    required Directory uploadDir,
  }) async {
    if (_server != null) await stopServer();

    _ipAddress = await findLocalIp();

    // Bind to any available port starting at 8080
    var p = 8080;
    while (_server == null && p < 8090) {
      try {
        _server = await HttpServer.bind(InternetAddress.anyIPv4, p);
        _port = p;
      } catch (_) {
        p++;
      }
    }
    if (_server == null) {
      _server = await HttpServer.bind(InternetAddress.anyIPv4, 0);
      _port = _server!.port;
    }

    _server!.listen((HttpRequest request) async {
      try {
        final path = request.uri.path;
        if (request.method == 'GET' && (path == '/' || path.isEmpty)) {
          _serveIndex(request, shareableFiles);
        } else if (request.method == 'GET' && path == '/download') {
          _serveDownload(request, shareableFiles);
        } else if (request.method == 'POST' && path == '/upload') {
          await _handleUpload(request, uploadDir);
        } else {
          request.response
            ..statusCode = HttpStatus.notFound
            ..write('Not found');
          await request.response.close();
        }
      } catch (e) {
        try {
          request.response
            ..statusCode = HttpStatus.internalServerError
            ..write('Server error: $e');
          await request.response.close();
        } catch (_) {}
      }
    });

    return serverUrl!;
  }

  void _serveIndex(
    HttpRequest request,
    List<({String name, int size, String path})> files,
  ) {
    final rows = files
        .map((f) {
          final safeName = htmlEscape.convert(f.name);
          final sizeMb = (f.size / (1024 * 1024)).toStringAsFixed(1);
          final encodedPath = Uri.encodeComponent(f.path);
          return '<tr>'
              '<td><strong>$safeName</strong></td>'
              '<td>$sizeMb MB</td>'
              '<td><a class="btn" href="/download?file=$encodedPath" download="$safeName">Download</a></td>'
              '</tr>';
        })
        .join('\n');

    final html =
        '''
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>TeDrive Wi-Fi Transfer</title>
  <style>
    body { font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif; margin: 0; background: #f8fafc; color: #0f172a; }
    .header { background: #2563eb; color: #fff; padding: 24px 20px; text-align: center; }
    .header h1 { margin: 0 0 6px 0; font-size: 24px; }
    .header p { margin: 0; opacity: 0.9; font-size: 14px; }
    .container { max-width: 800px; margin: 24px auto; padding: 0 16px; }
    .card { background: #fff; border-radius: 12px; padding: 20px; margin-bottom: 24px; box-shadow: 0 1px 3px rgba(0,0,0,0.1); }
    .card h2 { margin-top: 0; font-size: 18px; border-bottom: 1px solid #e2e8f0; padding-bottom: 12px; }
    .upload-zone { border: 2px dashed #94a3b8; border-radius: 8px; padding: 32px; text-align: center; cursor: pointer; transition: border-color .2s; }
    .upload-zone:hover { border-color: #2563eb; }
    table { width: 100%; border-collapse: collapse; margin-top: 12px; }
    th, td { text-align: left; padding: 10px 12px; border-bottom: 1px solid #f1f5f9; font-size: 14px; }
    th { color: #64748b; font-weight: 600; }
    .btn { display: inline-block; background: #2563eb; color: #fff; text-decoration: none; padding: 6px 14px; border-radius: 6px; font-size: 13px; font-weight: 500; }
    .btn:hover { background: #1d4ed8; }
  </style>
</head>
<body>
  <div class="header">
    <h1>TeDrive Wi-Fi Transfer</h1>
    <p>Connected directly to phone over local Wi-Fi — zero data usage</p>
  </div>
  <div class="container">
    <div class="card">
      <h2>Send files to phone</h2>
      <form action="/upload" method="post" enctype="multipart/form-data">
        <div class="upload-zone" onclick="document.getElementById('fileInput').click()">
          <p><strong>Click to choose files or drop files here</strong></p>
          <input type="file" id="fileInput" name="file" multiple style="display:none" onchange="this.form.submit()">
          <span style="font-size:13px;color:#64748b">Files save straight to TeDrive on your phone</span>
        </div>
      </form>
    </div>
    <div class="card">
      <h2>Available files on phone (${files.length})</h2>
      ${files.isEmpty ? '<p style="color:#64748b">No offline files cached on phone.</p>' : '''
      <table>
        <thead><tr><th>File name</th><th>Size</th><th>Action</th></tr></thead>
        <tbody>$rows</tbody>
      </table>'''}
    </div>
  </div>
</body>
</html>
''';

    request.response
      ..headers.contentType = ContentType.html
      ..write(html);
    request.response.close();
  }

  void _serveDownload(
    HttpRequest request,
    List<({String name, int size, String path})> files,
  ) {
    final fileParam = request.uri.queryParameters['file'];
    if (fileParam == null || fileParam.isEmpty) {
      request.response
        ..statusCode = HttpStatus.badRequest
        ..write('Missing file parameter');
      request.response.close();
      return;
    }

    final target = File(fileParam);
    if (!target.existsSync()) {
      request.response
        ..statusCode = HttpStatus.notFound
        ..write('File not found');
      request.response.close();
      return;
    }

    final filename = target.uri.pathSegments.last;
    request.response.headers.add(
      'Content-Disposition',
      'attachment; filename="$filename"',
    );
    request.response.headers.contentType = ContentType.binary;
    target.openRead().pipe(request.response);
  }

  Future<void> _handleUpload(HttpRequest request, Directory uploadDir) async {
    uploadDir.createSync(recursive: true);
    final contentType = request.headers.contentType;
    final boundary = contentType?.parameters['boundary'];

    final builder = BytesBuilder(copy: false);
    await for (final chunk in request) {
      builder.add(chunk);
    }
    final all = builder.takeBytes();

    if (boundary != null && all.isNotEmpty) {
      final boundaryBytes = utf8.encode('--$boundary');
      var pos = 0;
      while (pos < all.length) {
        final bIdx = _findBytes(all, boundaryBytes, pos);
        if (bIdx == -1) break;
        final partStart = bIdx + boundaryBytes.length;
        final nextB = _findBytes(all, boundaryBytes, partStart);
        if (nextB == -1) break;

        final partData = all.sublist(partStart, nextB);
        final headerEnd = _findBytes(partData, [13, 10, 13, 10], 0);
        if (headerEnd != -1) {
          final headerText = utf8.decode(
            partData.sublist(0, headerEnd),
            allowMalformed: true,
          );
          final match = RegExp(r'filename="([^"]+)"').firstMatch(headerText);
          final filename =
              match?.group(1) ??
              'upload_${DateTime.now().millisecondsSinceEpoch}';
          final bodyStart = headerEnd + 4;
          var bodyEnd = partData.length;
          if (bodyEnd >= 2 &&
              partData[bodyEnd - 2] == 13 &&
              partData[bodyEnd - 1] == 10) {
            bodyEnd -= 2;
          }
          if (bodyEnd > bodyStart) {
            final fileBytes = partData.sublist(bodyStart, bodyEnd);
            final dest = File('${uploadDir.path}/$filename');
            await dest.writeAsBytes(fileBytes, flush: true);
            _receivedFiles.add(dest);
            _onFileReceived.add(dest);
          }
        }
        pos = nextB;
      }
    } else if (all.isNotEmpty) {
      final filename = 'upload_${DateTime.now().millisecondsSinceEpoch}';
      final dest = File('${uploadDir.path}/$filename');
      await dest.writeAsBytes(all, flush: true);
      _receivedFiles.add(dest);
      _onFileReceived.add(dest);
    }

    request.response
      ..statusCode = HttpStatus.ok
      ..headers.contentType = ContentType.html
      ..write(
        '<html><body><h3>Upload complete!</h3><a href="/">Back to transfer</a></body></html>',
      );
    await request.response.close();
  }

  static int _findBytes(Uint8List src, List<int> pattern, int start) {
    for (var i = start; i <= src.length - pattern.length; i++) {
      var match = true;
      for (var j = 0; j < pattern.length; j++) {
        if (src[i + j] != pattern[j]) {
          match = false;
          break;
        }
      }
      if (match) return i;
    }
    return -1;
  }

  Future<void> stopServer() async {
    await _server?.close(force: true);
    _server = null;
    _ipAddress = null;
  }
}
