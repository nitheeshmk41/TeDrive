import 'dart:io';

import 'package:path_provider/path_provider.dart';

import 'device.dart' show isAndroid;
import 'stored_file.dart';

/// The list of drive files that Android's file picker shows under
/// "TeDrive". The picker runs outside the Flutter side of the app, so it
/// reads this small file instead of asking Telegram.
const _fileName = 'picker_catalogue.json';

Future<File?> _file() async {
  if (!isAndroid) return null;
  final dir = await getApplicationSupportDirectory();
  return File('${dir.path}/$_fileName');
}

Future<void> writePickerCatalogue(
  List<StoredFile> files,
  Map<int, String> thumbPaths,
) async {
  try {
    final file = await _file();
    if (file == null) return;
    final tmp = File('${file.path}.tmp');
    await tmp.writeAsString(encodePickerCatalogue(files, thumbPaths));
    await tmp.rename(file.path);
  } on FileSystemException {
    // The picker simply keeps showing the previous list.
  }
}

/// Removes the catalogue, so a signed-out drive is not listed.
Future<void> clearPickerCatalogue() async {
  try {
    final file = await _file();
    if (file != null && file.existsSync()) await file.delete();
  } on FileSystemException {
    // Nothing to remove.
  }
}
