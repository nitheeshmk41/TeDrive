import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:tedrive/wifi_transfer.dart';
import 'package:test/test.dart';

void main() {
  final service = WifiTransferService.instance;
  late Directory tmp;
  late File photo;
  late File notes;
  late Uri base;
  late HttpClient client;
  var hasNetwork = true;

  Future<HttpClientResponse> get(
    String path, {
    Map<String, String> headers = const {},
  }) async {
    final request = await client.getUrl(base.resolve(path));
    headers.forEach(request.headers.set);
    return request.close();
  }

  Future<Uint8List> bytes(HttpClientResponse r) async {
    final b = BytesBuilder();
    await r.forEach(b.add);
    return b.takeBytes();
  }

  setUpAll(() async {
    tmp = Directory.systemTemp.createTempSync('tedrive_wifi_test');
    photo = File('${tmp.path}/photo.jpg')
      ..writeAsBytesSync(List.generate(300000, (i) => i % 251));
    notes = File('${tmp.path}/notes.txt')..writeAsStringSync('hello wifi');
    // A file that is NOT offered: it must never be reachable.
    File('${tmp.path}/secret.txt').writeAsStringSync('secret');
    if (await WifiTransferService.findLocalIp() == null) {
      hasNetwork = false;
      return;
    }
    await service.start(
      files: () => [
        (name: 'photo.jpg', size: 300000, path: photo.path, thumb: null),
        (name: 'notes.txt', size: 10, path: notes.path, thumb: null),
      ],
      uploadDir: Directory('${tmp.path}/in'),
      deviceName: 'Test phone',
    );
    final port = Uri.parse(service.shortUrl!).port;
    base = Uri.parse('http://127.0.0.1:$port/');
    client = HttpClient();
  });

  tearDownAll(() async {
    if (hasNetwork) {
      client.close(force: true);
      await service.stop();
    }
    tmp.deleteSync(recursive: true);
  });

  test('the page loads without the code, but nothing else does', () async {
    if (!hasNetwork) return;
    final page = await get('/');
    expect(page.statusCode, 200);
    expect(utf8.decode(await bytes(page)), contains('TeDrive Wi-Fi transfer'));
    for (final path in [
      '/api/info',
      '/file?id=0',
      '/zip?ids=0',
      '/api/info?k=000000x',
    ]) {
      final r = await get(path);
      expect(r.statusCode, 403, reason: path);
      await r.drain<void>();
    }
  });

  test('lists the offered files with the code', () async {
    if (!hasNetwork) return;
    final r = await get('/api/info?k=${service.code}');
    final info = jsonDecode(utf8.decode(await bytes(r))) as Map;
    expect(info['device'], 'Test phone');
    expect((info['files'] as List).map((f) => f['name']), [
      'photo.jpg',
      'notes.txt',
    ]);
    expect(service.connected, isTrue);
  });

  test('downloads a file, whole and in part', () async {
    if (!hasNetwork) return;
    final whole = await get('/file?id=0&k=${service.code}');
    expect(whole.statusCode, 200);
    expect(whole.headers.value('content-disposition'), contains('photo.jpg'));
    expect(await bytes(whole), photo.readAsBytesSync());

    final part = await get(
      '/file?id=0&k=${service.code}',
      headers: {'range': 'bytes=100-199'},
    );
    expect(part.statusCode, 206);
    expect(part.headers.value('content-range'), 'bytes 100-199/300000');
    expect(await bytes(part), photo.readAsBytesSync().sublist(100, 200));
  });

  test('only offered files can be fetched', () async {
    if (!hasNetwork) return;
    for (final path in ['/file?id=2', '/file?id=-1', '/file?id=secret.txt']) {
      final r = await get('$path&k=${service.code}');
      expect(r.statusCode, 404, reason: path);
      await r.drain<void>();
    }
    final byPath = await get(
      '/file?file=${Uri.encodeComponent('${tmp.path}/secret.txt')}'
      '&k=${service.code}',
    );
    expect(byPath.statusCode, 404);
    await byPath.drain<void>();
  });

  test('several files arrive as a valid zip', () async {
    if (!hasNetwork) return;
    final r = await get('/zip?ids=0,1&k=${service.code}');
    expect(r.statusCode, 200);
    final archive = ZipDecoder().decodeBytes(await bytes(r));
    expect(archive.files.map((f) => f.name), ['photo.jpg', 'notes.txt']);
    expect(archive.files[0].content, photo.readAsBytesSync());
    expect(utf8.decode(archive.files[1].content as List<int>), 'hello wifi');
  });

  test('receives a file and keeps it inside the upload folder', () async {
    if (!hasNetwork) return;
    Future<int> send(String name, List<int> body) async {
      final request = await client.postUrl(
        base.resolve(
          '/upload?name=${Uri.encodeComponent(name)}&k=${service.code}',
        ),
      );
      request.contentLength = body.length;
      request.add(body);
      final r = await request.close();
      await r.drain<void>();
      return r.statusCode;
    }

    final received = <File>[];
    final sub = service.onFileReceived.listen(received.add);
    expect(await send('from laptop.txt', utf8.encode('sent over wifi')), 200);
    expect(await send('../../escape.txt', utf8.encode('x')), 200);
    expect(await send('from laptop.txt', utf8.encode('second')), 200);
    await Future<void>.delayed(const Duration(milliseconds: 100));
    await sub.cancel();

    final inDir = Directory('${tmp.path}/in');
    expect(received.length, 3);
    for (final f in received) {
      expect(f.parent.path, inDir.path, reason: f.path);
    }
    expect(received[0].readAsStringSync(), 'sent over wifi');
    // A second file of the same name does not overwrite the first.
    expect(received[2].path, isNot(received[0].path));
    expect(File('${tmp.path}/escape.txt').existsSync(), isFalse);
    expect(
      service.activity.where((a) => a.direction == WifiDirection.received),
      hasLength(3),
    );
  });

  test('without the code, nothing can be uploaded', () async {
    if (!hasNetwork) return;
    final request = await client.postUrl(base.resolve('/upload?name=a.txt'));
    request.add(utf8.encode('x'));
    final r = await request.close();
    expect(r.statusCode, 403);
    await r.drain<void>();
  });

  // Last: it locks the server.
  test('guessing the code locks the transfer', () async {
    if (!hasNetwork) return;
    // Earlier tests already used a few wrong codes.
    for (var i = 0; i < WifiTransferService.maxWrongCodes; i++) {
      if (service.lockedOut) break;
      final r = await get('/api/info?k=wrong$i');
      expect(r.statusCode, 403);
      await r.drain<void>();
    }
    expect(service.lockedOut, isTrue);
    // Even the right code is refused now.
    final r = await get('/api/info?k=${service.code}');
    expect(r.statusCode, 429);
    await r.drain<void>();
  });
}
