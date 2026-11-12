import 'dart:convert';

import 'package:tedrive/http_range.dart';
import 'package:tedrive/stored_file.dart';
import 'package:test/test.dart';

const _sha = '383c77bfba9daab340231916497249bda3c31ea2ae72a3fdf67d61dd42bfdd66';

Json _message(String caption, {String name = 'a.jpg', int id = 1}) => {
  'id': id,
  'date': 1700000000,
  'content': {
    '@type': 'messageDocument',
    'document': {
      'file_name': name,
      'document': {'id': id, 'size': 2048, 'expected_size': 2048},
    },
    'caption': {'text': caption},
  },
};

void main() {
  group('device name in captions', () {
    test('is written and read back', () {
      final caption = buildCaption(
        sha256: _sha,
        folder: 'Camera',
        device: 'Samsung SM-A525F',
      );
      expect(caption, 'sha256:$_sha\nfolder:Camera\ndevice:Samsung SM-A525F');
      final f = StoredFile.fromMessage(_message(caption))!;
      expect(f.device, 'Samsung SM-A525F');
      expect(f.folder, 'Camera');
      expect(f.sha256, _sha);
    });

    test('survives moving the file to another album', () {
      final f = StoredFile.fromMessage(
        _message(buildCaption(sha256: _sha, device: 'Laptop')),
      )!;
      final moved = f.withFolder('Trip').withLocalPath('/x');
      expect(moved.device, 'Laptop');
      expect(moved.caption, 'sha256:$_sha\nfolder:Trip\ndevice:Laptop');
    });

    test('is absent on files uploaded by older versions', () {
      final f = StoredFile.fromMessage(_message('sha256:$_sha'))!;
      expect(f.device, isNull);
      expect(f.caption, 'sha256:$_sha');
    });

    test('a name with odd spacing is flattened to one line', () {
      expect(buildCaption(device: ' My\nPhone '), 'device:My Phone');
      expect(buildCaption(device: '   '), '');
    });

    test('all four keys together round-trip', () {
      final taken = DateTime.fromMillisecondsSinceEpoch(1600000000 * 1000);
      final caption = buildCaption(
        sha256: _sha,
        folder: 'WhatsApp Images',
        taken: taken,
        device: 'Pixel 7',
      );
      final f = StoredFile.fromMessage(_message(caption))!;
      expect(f.caption, caption);
      expect(f.taken, taken);
      expect(f.date, taken);
    });
  });

  test('mimeOf gives apps a usable type', () {
    expect(mimeOf('IMG_1.JPG'), 'image/jpeg');
    expect(mimeOf('clip.mp4'), 'video/mp4');
    expect(mimeOf('voice.opus'), 'audio/ogg');
    expect(mimeOf('bill.pdf'), 'application/pdf');
    expect(mimeOf('sheet.xlsx'), startsWith('application/vnd.openxml'));
    expect(mimeOf('README'), 'application/octet-stream');
    expect(mimeOf('strange.xyz'), 'application/octet-stream');
  });

  group('parseRange (video streaming)', () {
    test('no header means the whole file', () {
      expect(parseRange(null, 1000), (0, 999));
    });

    test('open-ended and bounded ranges', () {
      expect(parseRange('bytes=0-', 1000), (0, 999));
      expect(parseRange('bytes=200-', 1000), (200, 999));
      expect(parseRange('bytes=200-299', 1000), (200, 299));
      expect(parseRange('bytes=0-0', 1000), (0, 0));
    });

    test('an end past the file is clamped', () {
      expect(parseRange('bytes=900-5000', 1000), (900, 999));
    });

    test('suffix range is the last N bytes', () {
      expect(parseRange('bytes=-100', 1000), (900, 999));
      expect(parseRange('bytes=-5000', 1000), (0, 999));
    });

    test('unsatisfiable or malformed ranges are rejected', () {
      expect(parseRange('bytes=1000-', 1000), isNull);
      expect(parseRange('bytes=500-400', 1000), isNull);
      expect(parseRange('bytes=-0', 1000), isNull);
      expect(parseRange('bytes=-', 1000), isNull);
      expect(parseRange('items=0-5', 1000), isNull);
      expect(parseRange('bytes=a-b', 1000), isNull);
      expect(parseRange(null, 0), isNull);
    });
  });

  test('the file-picker catalogue has what the Android side reads', () {
    final files = [
      StoredFile.fromMessage(
        _message(buildCaption(folder: 'Camera'), name: 'a.jpg', id: 7),
      )!.withLocalPath('/data/a.jpg'),
      StoredFile.fromMessage(_message('', name: 'notes.pdf', id: 8))!,
    ];
    final decoded = jsonDecode(
      encodePickerCatalogue(files, {7: '/cache/t7.jpg'}),
    ) as Map<String, dynamic>;
    final list = (decoded['files'] as List).cast<Map<String, dynamic>>();
    expect(list, hasLength(2));
    expect(list[0], {
      'id': 7,
      'name': 'a.jpg',
      'size': 2048,
      'time': 1700000000 * 1000,
      'folder': 'Camera',
      'mime': 'image/jpeg',
      'path': '/data/a.jpg',
      'thumb': '/cache/t7.jpg',
    });
    expect(list[1]['folder'], isNull);
    expect(list[1]['path'], isNull);
    expect(list[1]['thumb'], isNull);
    expect(list[1]['mime'], 'application/pdf');
  });
}
