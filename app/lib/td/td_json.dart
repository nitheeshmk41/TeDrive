// Exports the FFI-backed TDLib wrapper on native platforms, and a stub
// on web platforms where dart:ffi is unavailable.
export 'td_json_stub.dart' if (dart.library.ffi) 'td_json_ffi.dart';
