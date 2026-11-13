import 'package:tedrive/stored_file.dart';
import 'package:test/test.dart';

void main() {
  test('share links point at the TeDrive share page', () {
    expect(
      friendlyShareLink('https://t.me/tedrive_abc123/4'),
      'https://tedrive.vercel.app/s/?c=tedrive_abc123&p=4',
    );
    expect(friendlyShareLink('https://example.com/x'), 'https://example.com/x');
  });
}
