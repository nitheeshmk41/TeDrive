import 'dart:io';

import 'package:tedrive/config.dart';
import 'package:tedrive/version.dart';
import 'package:test/test.dart';

void main() {
  test('appVersion matches pubspec.yaml', () {
    final pubspec = File('pubspec.yaml').readAsStringSync();
    final m = RegExp(r'^version:\s*([\d.]+)', multiLine: true).firstMatch(pubspec);
    expect(m!.group(1), appVersion);
  });

  test('parses release tags', () {
    expect(parseVersion('v2'), [2, 0, 0]);
    expect(parseVersion('v2.1.3'), [2, 1, 3]);
    expect(parseVersion('v2-beta'), [2, 0, 0]);
    expect(parseVersion('nonsense'), [0, 0, 0]);
  });

  test('compares versions', () {
    expect(isNewer('v3.0.0', '2.0.0'), isTrue);
    expect(isNewer('v2.0.1', '2.0.0'), isTrue);
    expect(isNewer('v2.0.0', '2.0.0'), isFalse);
    expect(isNewer('v2-beta', '2.0.0'), isFalse);
    expect(isNewer('v1.9.9', '2.0.0'), isFalse);
  });
}
