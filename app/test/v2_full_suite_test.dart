import 'dart:convert';
import 'dart:typed_data';

import 'package:test/test.dart';

import 'package:tedrive/persisted_queue.dart';
import 'package:tedrive/stored_file.dart';
import 'package:tedrive/vault_service.dart';

void main() {
  group('Nested Folders', () {
    test('normalizeFolder handles nested paths and redundant slashes', () {
      expect(normalizeFolder('Photos//2026/Goa/'), 'Photos/2026/Goa');
      expect(
        normalizeFolder(r'Documents\Work\Invoices'),
        'Documents/Work/Invoices',
      );
      expect(normalizeFolder('  Root / Sub  / Deep /  '), 'Root/Sub/Deep');
    });

    test('parentFolder extracts parent path or null for root', () {
      expect(parentFolder('Photos/2026/Goa'), 'Photos/2026');
      expect(parentFolder('Photos/2026'), 'Photos');
      expect(parentFolder('Photos'), isNull);
      expect(parentFolder(null), isNull);
    });

    test('folderBaseName extracts the leaf segment', () {
      expect(folderBaseName('Photos/2026/Goa'), 'Goa');
      expect(folderBaseName('Documents'), 'Documents');
      expect(folderBaseName('A/B/C/D'), 'D');
    });

    test('folderBreadcrumbs builds cumulative segments', () {
      expect(folderBreadcrumbs('Photos/2026/Trip'), [
        'Photos',
        'Photos/2026',
        'Photos/2026/Trip',
      ]);
      expect(folderBreadcrumbs('Single'), ['Single']);
      expect(folderBreadcrumbs(''), isEmpty);
    });

    test('directSubfolders extracts immediate child folders only', () {
      final files = [
        _file(id: 1, folder: 'Photos/2025/Summer'),
        _file(id: 2, folder: 'Photos/2026/Goa'),
        _file(id: 3, folder: 'Photos/2026/Ooty'),
        _file(id: 4, folder: 'Documents/Taxes'),
        _file(id: 5, folder: 'TopLevelOnly'),
        _file(id: 6, folder: null),
      ];

      // Root level subfolders
      expect(directSubfolders(files), ['Documents', 'Photos', 'TopLevelOnly']);

      // Subfolders under Photos
      expect(directSubfolders(files, 'Photos'), ['Photos/2025', 'Photos/2026']);

      // Subfolders under Photos/2026
      expect(directSubfolders(files, 'Photos/2026'), [
        'Photos/2026/Goa',
        'Photos/2026/Ooty',
      ]);
    });

    test('filesInFolder filters direct vs recursive files', () {
      final files = [
        _file(id: 1, folder: 'Work'),
        _file(id: 2, folder: 'Work/2026'),
        _file(id: 3, folder: 'Work/2026/Invoices'),
        _file(id: 4, folder: 'Personal'),
      ];

      // Non-recursive: only files directly in 'Work'
      expect(
        filesInFolder(files, 'Work', recursive: false).map((f) => f.messageId),
        [1],
      );

      // Recursive: files in 'Work' and all its subfolders
      expect(
        filesInFolder(files, 'Work', recursive: true).map((f) => f.messageId),
        [1, 2, 3],
      );
    });
  });

  group('GPS Location and Photo Details', () {
    test('GPS coordinates and camera round-trip through captions', () {
      final caption = buildCaption(
        sha256: 'a' * 64,
        location: (lat: 12.971598, lng: 77.594566),
        camera: 'Sony Alpha 7 IV',
      );

      expect(caption, contains('geo:12.971598,77.594566'));
      expect(caption, contains('camera:Sony Alpha 7 IV'));

      final message = {
        'id': 100,
        'date': 1700000000,
        'content': {
          '@type': 'messagePhoto',
          'photo': {
            'sizes': [
              {
                'width': 600,
                'photo': {
                  'id': 10,
                  'size': 5000,
                  'local': {'path': ''},
                },
              },
            ],
          },
          'caption': {'text': caption},
        },
      };

      final parsed = StoredFile.fromMessage(message);
      expect(parsed, isNotNull);
      expect(parsed!.location, isNotNull);
      expect(parsed.location!.lat, closeTo(12.971598, 0.000001));
      expect(parsed.location!.lng, closeTo(77.594566, 0.000001));
      expect(parsed.camera, 'Sony Alpha 7 IV');
    });

    test('geotaggedFiles filters items with GPS coordinates', () {
      final files = [
        _file(id: 1, location: (lat: 13.0827, lng: 80.2707)),
        _file(id: 2),
        _file(id: 3, location: (lat: 28.6139, lng: 77.2090)),
      ];

      final geo = geotaggedFiles(files);
      expect(geo.length, 2);
      expect(geo.map((f) => f.messageId), [1, 3]);
    });
  });

  group('Encrypted Vault', () {
    test('VaultCipher encrypts and decrypts with PBKDF2 + AES-CTR + HMAC', () {
      const secretDocument =
          'Aadhaar: 1234 5678 9012, Name: Nitheesh, DOB: 01/01/2000';
      final clearBytes = Uint8List.fromList(utf8.encode(secretDocument));
      const passphrase = 'MySuperSecretPassphrase#2026';

      final encrypted = VaultCipher.encrypt(clearBytes, passphrase);

      // Ciphertext must have magic header
      expect(utf8.decode(encrypted.sublist(0, 9)), VaultCipher.magic);
      // Ciphertext must be longer than plaintext (magic + salt + iv + mac)
      expect(encrypted.length, clearBytes.length + 9 + 16 + 16 + 32);
      // Ciphertext must not contain the plaintext string
      expect(
        utf8.decode(encrypted, allowMalformed: true),
        isNot(contains(secretDocument)),
      );

      // Decryption with correct passphrase succeeds
      final decrypted = VaultCipher.decrypt(encrypted, passphrase);
      expect(utf8.decode(decrypted), secretDocument);
    });

    test('VaultCipher rejects incorrect passphrase', () {
      final clearBytes = Uint8List.fromList(
        utf8.encode('PAN Card: ABCDE1234F'),
      );
      final encrypted = VaultCipher.encrypt(clearBytes, 'CorrectPassword');

      expect(
        () => VaultCipher.decrypt(encrypted, 'WrongPassword'),
        throwsA(isA<VaultAuthException>()),
      );
    });

    test('VaultCipher rejects tampered ciphertext', () {
      final clearBytes = Uint8List.fromList(utf8.encode('Certificates'));
      final encrypted = VaultCipher.encrypt(clearBytes, 'Pass');

      // Tamper one byte in the ciphertext body
      encrypted[encrypted.length - 1] ^= 0x01;

      expect(
        () => VaultCipher.decrypt(encrypted, 'Pass'),
        throwsA(isA<VaultAuthException>()),
      );
    });

    test('vault caption round-trip', () {
      final caption = buildCaption(
        sha256: 'b' * 64,
        isVault: true,
        folder: 'Documents/Vault/Aadhaar',
      );
      expect(caption, contains('vault:1'));

      final message = {
        'id': 200,
        'date': 1700000000,
        'content': {
          '@type': 'messageDocument',
          'document': {
            'file_name': 'aadhaar.pdf.vault',
            'document': {
              'id': 20,
              'size': 12000,
              'local': {'path': ''},
            },
          },
          'caption': {'text': caption},
        },
      };

      final parsed = StoredFile.fromMessage(message);
      expect(parsed, isNotNull);
      expect(parsed!.isVault, isTrue);
      expect(parsed.folder, 'Documents/Vault/Aadhaar');
    });

    test('VaultSession locks and unlocks', () {
      final session = VaultSession.instance;
      session.lock();
      expect(session.isUnlocked, isFalse);
      expect(session.currentPassphrase, isNull);

      session.unlock('secret123');
      expect(session.isUnlocked, isTrue);
      expect(session.currentPassphrase, 'secret123');

      session.lock();
      expect(session.isUnlocked, isFalse);
    });
  });

  group('Album Share Links', () {
    test('album share link round-trips through caption', () {
      const shareUrl = 'https://t.me/tedrive_share/88';
      final caption = buildCaption(sha256: 'c' * 64, albumShare: shareUrl);
      expect(caption, contains('albumshare:$shareUrl'));

      final message = {
        'id': 300,
        'date': 1700000000,
        'content': {
          '@type': 'messageDocument',
          'document': {
            'file_name': 'photo.jpg',
            'document': {
              'id': 30,
              'size': 4000,
              'local': {'path': ''},
            },
          },
          'caption': {'text': caption},
        },
      };

      final parsed = StoredFile.fromMessage(message);
      expect(parsed, isNotNull);
      expect(parsed!.albumShareLink, shareUrl);
    });
  });

  group('Persisted Upload Queue', () {
    test('QueuedUploadItem serializes and deserializes cleanly', () {
      final item = QueuedUploadItem(
        path: '/storage/emulated/0/DCIM/pic.jpg',
        name: 'pic.jpg',
        size: 204800,
        folder: 'Photos/2026',
        taken: DateTime.fromMillisecondsSinceEpoch(1700000000000),
        knownSha: 'e' * 64,
        isVault: true,
      );

      final json = item.toJson();
      final restored = QueuedUploadItem.fromJson(json);

      expect(restored, isNotNull);
      expect(restored!.path, item.path);
      expect(restored.name, item.name);
      expect(restored.size, item.size);
      expect(restored.folder, item.folder);
      expect(restored.taken, item.taken);
      expect(restored.knownSha, item.knownSha);
      expect(restored.isVault, isTrue);
    });
  });
}

StoredFile _file({
  required int id,
  String? folder,
  ({double lat, double lng})? location,
}) => StoredFile(
  messageId: id,
  fileId: id * 10,
  name: 'file_$id.jpg',
  size: 1024,
  date: DateTime.fromMillisecondsSinceEpoch(1700000000000 + id * 1000),
  folder: folder,
  location: location,
);
