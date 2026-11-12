import 'dart:async';
import 'dart:convert';
import 'dart:isolate';

import 'package:flutter/foundation.dart';

import '../json.dart';
import 'td_json.dart';
import 'web_bridge.dart';

export '../json.dart';

class TdError implements Exception {
  TdError(this.code, this.message);
  final int code;
  final String message;

  @override
  String toString() => 'Telegram error $code: $message';
}

/// Thrown by [TdClient.start] when TDLib could not be loaded.
class TdLibraryMissing implements Exception {
  @override
  String toString() => kIsWeb
      ? 'Telegram\'s library could not be loaded in this browser.'
      : 'The Telegram library (tdjson) was not found next to the app.';
}

/// Talks to one TDLib client at a time: matches responses to requests and
/// exposes updates. [open] can be called again after the client has closed
/// (logout, or new API credentials) to get a fresh client.
///
/// On Android and desktop TDLib is a native library called through FFI. In
/// the browser it is tdweb (TDLib compiled to WebAssembly), see [WebTd].
class TdClient {
  late final TdJson _td;
  int _clientId = 0;
  final _pending = <String, Completer<Json>>{};
  final _updates = StreamController<Json>.broadcast();
  int _seq = 0;

  /// Everything TDLib sends that is not a reply to a request.
  Stream<Json> get updates => _updates.stream;

  /// Loads the library and starts the receive loop. Call once.
  Future<void> start() async {
    if (kIsWeb) {
      if (!WebTd.available) throw TdLibraryMissing();
      return;
    }
    try {
      _td = TdJson.open();
    } on ArgumentError {
      throw TdLibraryMissing();
    }
    _td.execute(
      jsonEncode({'@type': 'setLogVerbosityLevel', 'new_verbosity_level': 1}),
    );
    final port = ReceivePort('tdlib-events');
    port.listen(_onRaw);
    await Isolate.spawn(tdReceiveLoop, port.sendPort, debugName: 'tdlib');
  }

  /// Creates a new TDLib client and makes it the current one.
  void open() {
    for (final completer in _pending.values) {
      completer.completeError(TdError(500, 'Client was closed'));
    }
    _pending.clear();
    if (kIsWeb) {
      // tdweb sends its first updates by itself.
      WebTd.create((json) => _updates.add(jsonDecode(json) as Json));
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
    if (kIsWeb) return _webRequest(body);
    final extra = '${++_seq}';
    final completer = Completer<Json>();
    _pending[extra] = completer;
    _td.send(_clientId, jsonEncode({...body, '@extra': extra}));
    return completer.future;
  }

  Future<Json> _webRequest(Json body) async {
    final reply = jsonDecode(await WebTd.send(jsonEncode(body))) as Json;
    if (reply['@type'] == 'error') {
      throw TdError(
        reply['code'] as int? ?? 500,
        reply['message'] as String? ?? 'Unknown error',
      );
    }
    return reply;
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
