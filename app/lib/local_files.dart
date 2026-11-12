import 'dart:io';

import 'package:flutter/foundation.dart';

/// Whether [path] points at a downloaded copy that can be used right now.
///
/// On the web there is no file system: a downloaded file is a `blob:` URL
/// held by the browser. Everywhere else it is a real file.
bool localExists(String? path) {
  if (path == null || path.isEmpty) return false;
  if (kIsWeb) return path.startsWith('blob:');
  return File(path).existsSync();
}
