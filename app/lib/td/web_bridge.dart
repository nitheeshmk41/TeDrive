// The browser TDLib bridge on the web, and a stub everywhere else.
export 'web_bridge_stub.dart' if (dart.library.js_interop) 'web_bridge_js.dart';
