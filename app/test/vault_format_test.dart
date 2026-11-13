import 'dart:convert';
import 'dart:typed_data';

import 'package:tedrive/vault_service.dart';
import 'package:test/test.dart';

void main() {
  final secret = Uint8List.fromList(utf8.encode('passport number 123'));

  test('new files use the stronger format and open again', () {
    final sw = Stopwatch()..start();
    final file = VaultCipher.encrypt(secret, 'correct horse');
    expect(utf8.decode(file.sublist(0, 9)), 'TEDVAULT2');
    expect(VaultCipher.decrypt(file, 'correct horse'), secret);
    // ignore: avoid_print
    print('encrypt + decrypt took ${sw.elapsedMilliseconds} ms');
  });

  test('files from older versions still open', () {
    final old = VaultCipher.encrypt(secret, 'correct horse', legacy: true);
    expect(utf8.decode(old.sublist(0, 9)), 'TEDVAULT1');
    expect(VaultCipher.decrypt(old, 'correct horse'), secret);
    expect(
      () => VaultCipher.decrypt(old, 'wrong'),
      throwsA(isA<VaultAuthException>()),
    );
  });

  test('the header cannot be swapped to weaken a file', () {
    final file = VaultCipher.encrypt(secret, 'correct horse');
    file[8] = '1'.codeUnitAt(0);
    expect(
      () => VaultCipher.decrypt(file, 'correct horse'),
      throwsA(isA<VaultAuthException>()),
    );
  });
}
