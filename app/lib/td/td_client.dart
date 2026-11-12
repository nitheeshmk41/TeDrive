import 'dart:async';
import 'dart:convert';
import 'dart:isolate';

import 'package:flutter/foundation.dart';

import '../json.dart';
import 'td_json.dart';

export '../json.dart';

class TdError implements Exception {
  TdError(this.code, this.message);
  final int code;
  final String message;

  @override
  String toString() => 'Telegram error $code: $message';
}

/// Talks to one TDLib client at a time: matches responses to requests and
/// exposes updates. [open] can be called again after the client has closed
/// (logout, or new API credentials) to get a fresh client.
class TdClient {
  late final TdJson _td;
  int _clientId = 0;
  bool _isSimulated = false;
  final _pending = <String, Completer<Json>>{};
  final _updates = StreamController<Json>.broadcast();
  int _seq = 0;

  /// Everything TDLib sends that is not a reply to a request.
  Stream<Json> get updates => _updates.stream;

  /// Loads the native library and starts the receive loop. Call once.
  Future<void> start() async {
    try {
      _td = TdJson.open();
      _td.execute(
        jsonEncode({'@type': 'setLogVerbosityLevel', 'new_verbosity_level': 1}),
      );
      if (kIsWeb) return;
      final port = ReceivePort('tdlib-events');
      port.listen(_onRaw);
      await Isolate.spawn(tdReceiveLoop, port.sendPort, debugName: 'tdlib');
    } catch (_) {
      // If native tdjson library cannot be opened (e.g. Windows without tdjson.dll)
      _isSimulated = true;
    }
  }

  /// Creates a new TDLib client and makes it the current one.
  void open() {
    for (final completer in _pending.values) {
      completer.completeError(TdError(500, 'Client was closed'));
    }
    _pending.clear();
    if (kIsWeb || _isSimulated) {
      Timer.run(() {
        _updates.add({
          '@type': 'updateAuthorizationState',
          'authorization_state': {
            '@type': 'authorizationStateWaitTdlibParameters',
          },
        });
      });
      return;
    }
    _clientId = _td.createClientId();
    // TDLib sends nothing until it gets a first request.
    unawaited(
      request({'@type': 'getOption', 'name': 'version'})
          .catchError((_) => <String, dynamic>{}),
    );
  }

  /// Sends a request and completes with the reply, or throws [TdError].
  Future<Json> request(Json body) {
    if (kIsWeb || _isSimulated) {
      return _handleWebRequest(body);
    }
    final extra = '${++_seq}';
    final completer = Completer<Json>();
    _pending[extra] = completer;
    _td.send(_clientId, jsonEncode({...body, '@extra': extra}));
    return completer.future;
  }

  Future<Json> _handleWebRequest(Json body) async {
    final type = body['@type'] as String? ?? '';
    switch (type) {
      case 'getOption':
        return {'@type': 'optionValueString', 'value': '1.8.0'};
      case 'setTdlibParameters':
        Timer(const Duration(milliseconds: 100), () {
          _updates.add({
            '@type': 'updateAuthorizationState',
            'authorization_state': {
              '@type': 'authorizationStateWaitPhoneNumber',
            },
          });
        });
        return {'@type': 'ok'};
      case 'setAuthenticationPhoneNumber':
        Timer(const Duration(milliseconds: 200), () {
          _updates.add({
            '@type': 'updateAuthorizationState',
            'authorization_state': {
              '@type': 'authorizationStateWaitCode',
            },
          });
        });
        return {'@type': 'ok'};
      case 'checkAuthenticationCode':
      case 'checkAuthenticationPassword':
        Timer(const Duration(milliseconds: 200), () {
          _updates.add({
            '@type': 'updateAuthorizationState',
            'authorization_state': {
              '@type': 'authorizationStateReady',
            },
          });
        });
        return {'@type': 'ok'};
      case 'logOut':
      case 'close':
        Timer(const Duration(milliseconds: 100), () {
          _updates.add({
            '@type': 'updateAuthorizationState',
            'authorization_state': {
              '@type': 'authorizationStateClosed',
            },
          });
        });
        return {'@type': 'ok'};
      case 'getMe':
        return {
          '@type': 'user',
          'id': 12345678,
          'first_name': 'Web Demo',
          'is_premium': false,
        };
      case 'loadChats':
        return {'@type': 'ok'};
      case 'searchChats':
      case 'searchChatsOnServer':
        return {
          '@type': 'chats',
          'chat_ids': [-1001234567890],
        };
      case 'getChat':
      case 'createNewSupergroupChat':
        return {
          '@type': 'chat',
          'id': -1001234567890,
          'title': body['title'] ?? 'TeDrive [Web Demo]',
          'type': {'@type': 'chatTypeSupergroup', 'is_channel': true},
        };
      case 'getChatHistory':
        final fromId = body['from_message_id'] as int? ?? 0;
        if (fromId != 0) {
          return {'@type': 'messages', 'total_count': 0, 'messages': []};
        }
        final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
        return {
          '@type': 'messages',
          'total_count': 4,
          'messages': [
            {
              'id': 1001,
              'date': now - 3600,
              'content': {
                '@type': 'messagePhoto',
                'photo': {
                  'sizes': [
                    {
                      'type': 'm',
                      'photo': {
                        'id': 201,
                        'size': 1024 * 720,
                        'expected_size': 1024 * 720,
                        'local': {
                          'is_downloading_completed': false,
                          'path': '',
                        },
                      },
                    }
                  ],
                },
                'caption': {
                  'text': '#folder/Camera #sha256/1111222233334444555566667777888899990000aaaabbbbccccddddeeeeffff',
                },
              },
            },
            {
              'id': 1002,
              'date': now - 86400,
              'content': {
                '@type': 'messageVideo',
                'video': {
                  'file_name': 'Beach_Sunset.mp4',
                  'video': {
                    'id': 202,
                    'size': 1024 * 1024 * 38,
                    'expected_size': 1024 * 1024 * 38,
                    'local': {
                      'is_downloading_completed': false,
                      'path': '',
                    },
                  },
                },
                'caption': {
                  'text': '#folder/Camera #sha256/222233334444555566667777888899990000aaaabbbbccccddddeeeeffff1111',
                },
              },
            },
            {
              'id': 1003,
              'date': now - 86400 * 3,
              'content': {
                '@type': 'messageDocument',
                'document': {
                  'file_name': 'Annual_Financial_Report.pdf',
                  'document': {
                    'id': 203,
                    'size': 1024 * 512,
                    'expected_size': 1024 * 512,
                    'local': {
                      'is_downloading_completed': false,
                      'path': '',
                    },
                  },
                },
                'caption': {
                  'text': '#folder/Documents #sha256/33334444555566667777888899990000aaaabbbbccccddddeeeeffff11112222',
                },
              },
            },
            {
              'id': 1004,
              'date': now - 86400 * 7,
              'content': {
                '@type': 'messageDocument',
                'document': {
                  'file_name': 'WhatsApp_Media_Backup.zip',
                  'document': {
                    'id': 204,
                    'size': 1024 * 1024 * 15,
                    'expected_size': 1024 * 1024 * 15,
                    'local': {
                      'is_downloading_completed': false,
                      'path': '',
                    },
                  },
                },
                'caption': {
                  'text': '#folder/WhatsApp #sha256/4444555566667777888899990000aaaabbbbccccddddeeeeffff111122223333',
                },
              },
            },
          ],
        };
      case 'getFile':
      case 'downloadFile':
        return {
          '@type': 'file',
          'id': body['file_id'] ?? 1,
          'size': 1024 * 500,
          'expected_size': 1024 * 500,
          'local': {
            'is_downloading_completed': true,
            'path': 'web_demo',
          },
        };
      default:
        return {'@type': 'ok'};
    }
  }

  void _onRaw(dynamic raw) {
    final Json event = jsonDecode(raw as String) as Json;
    // Ignore leftovers from a client that has been replaced.
    final clientId = event['@client_id'];
    if (clientId != null && clientId != _clientId) return;
    final extra = event['@extra'];
    final completer = extra is String ? _pending.remove(extra) : null;
    if (completer == null) {
      _updates.add(event);
      return;
    }
    if (event['@type'] == 'error') {
      completer.completeError(
        TdError(event['code'] as int, event['message'] as String),
      );
    } else {
      completer.complete(event);
    }
  }
}
