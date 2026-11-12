import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'http_range.dart';
import 'stored_file.dart';
import 'tedrive_service.dart';

/// A tiny HTTP server on the phone's loopback address that lets the video
/// and audio player stream a file from Telegram. The player asks for byte
/// ranges; each range is fetched from Telegram on demand, so playback
/// starts without downloading the whole file.
///
/// Only this phone can reach it, and every URL carries a random token so
/// other apps on the phone cannot guess one.
class MediaServer {
  MediaServer(this._service);

  final TeDriveService _service;
  HttpServer? _server;
  final Map<int, StoredFile> _files = {};
  final String _token = [
    for (var i = 0; i < 16; i++)
      Random.secure().nextInt(256).toRadixString(16).padLeft(2, '0'),
  ].join();

  static const _chunk = 512 * 1024;

  /// A URL the media player can open for [file].
  Future<Uri> urlFor(StoredFile file) async {
    final server = _server ??= await _start();
    _files[file.messageId] = file;
    return Uri(
      scheme: 'http',
      host: InternetAddress.loopbackIPv4.address,
      port: server.port,
      pathSegments: [_token, '${file.messageId}', safeFileName(file.name)],
    );
  }

  Future<HttpServer> _start() async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen(
      (request) => _handle(request).catchError((_) {}),
      onError: (_) {},
    );
    return server;
  }

  Future<void> close() async {
    await _server?.close(force: true);
    _server = null;
    _files.clear();
  }

  Future<void> _handle(HttpRequest request) async {
    final response = request.response;
    final segments = request.uri.pathSegments;
    final file = segments.length >= 2 && segments[0] == _token
        ? _files[int.tryParse(segments[1])]
        : null;
    if (file == null) {
      response.statusCode = HttpStatus.notFound;
      return response.close();
    }
    final total = file.size;
    final range = parseRange(request.headers.value('range'), total);
    if (range == null) {
      response.statusCode = HttpStatus.requestedRangeNotSatisfiable;
      response.headers.set('Content-Range', 'bytes */$total');
      return response.close();
    }
    final (start, end) = range;
    response.headers
      ..set('Accept-Ranges', 'bytes')
      ..set('Content-Type', mimeOf(file.name))
      ..contentLength = end - start + 1;
    if (request.headers.value('range') != null) {
      response.statusCode = HttpStatus.partialContent;
      response.headers.set('Content-Range', 'bytes $start-$end/$total');
    }
    if (request.method == 'HEAD') return response.close();

    try {
      final local = await _service.localPathOf(file.fileId);
      if (local != null) {
        await response.addStream(File(local).openRead(start, end + 1));
      } else {
        var position = start;
        var stalls = 0;
        while (position <= end) {
          final want = min(_chunk, end - position + 1);
          final data = await _service.readPart(file.fileId, position, want);
          if (data.isEmpty) {
            // Another range request can interrupt this one; try again.
            if (++stalls > 20) break;
            await Future<void>.delayed(const Duration(milliseconds: 150));
            continue;
          }
          stalls = 0;
          response.add(data);
          position += data.length;
          // Wait for the player to take the bytes before fetching more.
          await response.flush();
        }
      }
    } catch (_) {
      // The player closed the connection (seek or stop). Nothing to do.
    } finally {
      await response.close().catchError((_) {});
    }
  }
}
