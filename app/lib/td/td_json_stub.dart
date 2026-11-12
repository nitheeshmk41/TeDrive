// Web / non-FFI stub for TdJson.
// Used when compiling for Flutter Web where dart:ffi is unavailable.

class TdJson {
  TdJson._();

  factory TdJson.open() => TdJson._();

  int createClientId() => 1;

  void send(int clientId, String request) {}

  /// Blocks for up to [timeoutSeconds]. Returns null on timeout.
  String? receive(double timeoutSeconds) => null;

  String? execute(String request) => null;
}

/// No-op receive loop for platforms without dart:ffi or isolates.
void tdReceiveLoop(dynamic port) {}

