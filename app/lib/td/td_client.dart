import 'dart:async';
import 'dart:convert';
import 'dart:isolate';

import 'package:flutter/foundation.dart';

import '../json.dart';
import 'demo_backend.dart';
import 'td_json.dart';

export '../json.dart';

class TdError implements Exception {
  TdError(this.code, this.message);
  final int code;
  final String message;

  @override
  String toString() => 'Telegram error $code: $message';
}

/// Thrown by [TdClient.start] when TDLib's native library is not there.
class TdLibraryMissing implements Exception {
  @override
  String toString() =>
      'The Telegram library (tdjson) was not found next to the app.';
}

/// Talks to one TDLib client at a time: matches responses to requests and
/// exposes updates. [open] can be called again after the client has closed
/// (logout, or new API credentials) to get a fresh client.
///
/// On the web there is no TDLib. There the client runs against
/// [DemoBackend], which serves sample files and never contacts Telegram.
class TdClient {
  late final TdJson _td;
  DemoBackend? _demo;
  int _clientId = 0;
  final _pending = <String, Completer<Json>>{};
  final _updates = StreamController<Json>.broadcast();
  int _seq = 0;

  /// True when showing sample data instead of a real Telegram account.
  bool get isDemo => _demo != null;

  /// Everything TDLib sends that is not a reply to a request.
  Stream<Json> get updates => _updates.stream;

  /// Loads the native library and starts the receive loop. Call once.
  Future<void> start() async {
    if (kIsWeb) {
      _demo = DemoBackend(_updates.add);
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
    final demo = _demo;
    if (demo != null) {
      demo.open();
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
    final demo = _demo;
    if (demo != null) return demo.request(body);
    final extra = '${++_seq}';
    final completer = Completer<Json>();
    _pending[extra] = completer;
    _td.send(_clientId, jsonEncode({...body, '@extra': extra}));
    return completer.future;
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
