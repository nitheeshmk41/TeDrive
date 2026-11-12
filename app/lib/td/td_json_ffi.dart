// Minimal FFI binding to TDLib's JSON interface (libtdjson.so).
//
// Only four native functions are needed. Requests and responses are plain
// JSON, so this binding does not depend on the TDLib version.
import 'dart:ffi' as ffi;
import 'dart:isolate';

import 'package:ffi/ffi.dart';

typedef _CreateClientIdC = ffi.Int32 Function();
typedef _CreateClientIdDart = int Function();
typedef _SendC = ffi.Void Function(ffi.Int32, ffi.Pointer<Utf8>);
typedef _SendDart = void Function(int, ffi.Pointer<Utf8>);
typedef _ReceiveC = ffi.Pointer<Utf8> Function(ffi.Double);
typedef _ReceiveDart = ffi.Pointer<Utf8> Function(double);
typedef _ExecuteC = ffi.Pointer<Utf8> Function(ffi.Pointer<Utf8>);
typedef _ExecuteDart = ffi.Pointer<Utf8> Function(ffi.Pointer<Utf8>);

class TdJson {
  TdJson._(ffi.DynamicLibrary lib)
    : _createClientId = lib
          .lookupFunction<_CreateClientIdC, _CreateClientIdDart>(
            'td_create_client_id',
          ),
      _send = lib.lookupFunction<_SendC, _SendDart>('td_send'),
      _receive = lib.lookupFunction<_ReceiveC, _ReceiveDart>('td_receive'),
      _execute = lib.lookupFunction<_ExecuteC, _ExecuteDart>('td_execute');

  factory TdJson.open() => TdJson._(ffi.DynamicLibrary.open('libtdjson.so'));

  final _CreateClientIdDart _createClientId;
  final _SendDart _send;
  final _ReceiveDart _receive;
  final _ExecuteDart _execute;

  int createClientId() => _createClientId();

  void send(int clientId, String request) {
    final ptr = request.toNativeUtf8();
    try {
      _send(clientId, ptr);
    } finally {
      malloc.free(ptr);
    }
  }

  /// Blocks for up to [timeoutSeconds]. Returns null on timeout.
  String? receive(double timeoutSeconds) {
    final res = _receive(timeoutSeconds);
    return res == ffi.nullptr ? null : res.toDartString();
  }

  String? execute(String request) {
    final ptr = request.toNativeUtf8();
    try {
      final res = _execute(ptr);
      return res == ffi.nullptr ? null : res.toDartString();
    } finally {
      malloc.free(ptr);
    }
  }
}

/// Entry point of the background isolate that pulls events out of TDLib.
/// td_receive blocks, so it must not run on the UI isolate.
void tdReceiveLoop(SendPort port) {
  final td = TdJson.open();
  while (true) {
    final event = td.receive(1.0);
    if (event != null) port.send(event);
  }
}

