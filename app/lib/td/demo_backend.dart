import 'dart:async';

import '../json.dart';
import '../stored_file.dart' show buildCaption;

/// Stands in for TDLib in the web demo. It answers the handful of requests
/// the app makes with sample data, so the interface can be explored in a
/// browser. Nothing here contacts Telegram, and nothing is stored.
class DemoBackend {
  DemoBackend(this._emit);

  final void Function(Json update) _emit;
  static const _chatId = -1000000000001;
  final List<Json> _messages = _sampleMessages();

  void _auth(String state) => Timer.run(
    () => _emit({
      '@type': 'updateAuthorizationState',
      'authorization_state': {'@type': 'authorizationState$state'},
    }),
  );

  void open() => _auth('WaitTdlibParameters');

  Future<Json> request(Json body) async {
    switch (body['@type']) {
      case 'setTdlibParameters':
        // The demo has no account, so there is nothing to sign in to.
        _auth('Ready');
      case 'logOut' || 'close':
        _auth('Closed');
      case 'getMe':
        return {'@type': 'user', 'id': 1, 'is_premium': false};
      case 'searchChats' || 'searchChatsOnServer':
        return {
          '@type': 'chats',
          'chat_ids': [_chatId],
        };
      case 'getChat' || 'createNewSupergroupChat':
        return {
          '@type': 'chat',
          'id': _chatId,
          'title': 'TeDrive Storage',
          'type': {'@type': 'chatTypeSupergroup', 'is_channel': true},
        };
      case 'getChatHistory':
        return {
          '@type': 'messages',
          'messages': body['from_message_id'] == 0 ? _messages : const [],
        };
      case 'deleteMessages':
        final ids = (body['message_ids'] as List).toSet();
        _messages.removeWhere((m) => ids.contains(m['id']));
      case 'editMessageCaption':
        for (final m in _messages) {
          if (m['id'] == body['message_id']) {
            (m['content'] as Json)['caption'] = body['caption'];
          }
        }
      case 'getFile' || 'downloadFile':
        // Sample files have no contents to download.
        throw StateError('Sample files cannot be opened in the demo.');
    }
    return {'@type': 'ok'};
  }

  static List<Json> _sampleMessages() {
    final now = DateTime.now();
    var id = 0;
    Json file(
      String name,
      int kb, {
      required int daysAgo,
      String? folder,
      String device = 'Galaxy A52',
    }) {
      id++;
      final taken = now.subtract(Duration(days: daysAgo, hours: id));
      return {
        '@type': 'message',
        'id': id * 1048576,
        'date': taken.millisecondsSinceEpoch ~/ 1000,
        'content': {
          '@type': 'messageDocument',
          'document': {
            'file_name': name,
            'document': {
              'id': id,
              'size': kb * 1024,
              'expected_size': kb * 1024,
              'local': {'path': '', 'is_downloading_completed': false},
            },
          },
          'caption': {
            'text': buildCaption(folder: folder, taken: taken, device: device),
          },
        },
      };
    }

    return [
      file('IMG_2041.jpg', 3210, daysAgo: 0, folder: 'Camera'),
      file('IMG_2040.jpg', 2875, daysAgo: 0, folder: 'Camera'),
      file('VID_2039.mp4', 48210, daysAgo: 1, folder: 'Camera'),
      file('IMG_2038.jpg', 3055, daysAgo: 1, folder: 'Camera'),
      file('Screenshot_checkout.png', 412, daysAgo: 2, folder: 'Screenshots'),
      file('IMG-WA0031.jpg', 184, daysAgo: 3, folder: 'WhatsApp Images'),
      file('VID-WA0007.mp4', 9120, daysAgo: 3, folder: 'WhatsApp Video'),
      file('Voice note.m4a', 640, daysAgo: 5, device: 'Pixel 7'),
      file('Rent agreement.pdf', 512, daysAgo: 9, folder: 'Documents'),
      file(
        'Budget 2026.xlsx',
        96,
        daysAgo: 14,
        folder: 'Documents',
        device: 'Laptop',
      ),
      file('IMG_1987.jpg', 2990, daysAgo: 40, folder: 'Camera'),
      file('IMG_1986.jpg', 3120, daysAgo: 40, folder: 'Camera'),
      file('Trip video.mp4', 215300, daysAgo: 41, folder: 'Camera'),
      file('Project backup.zip', 15360, daysAgo: 70, device: 'Laptop'),
    ];
  }
}
