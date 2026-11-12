import 'package:flutter/services.dart';

/// A small JPEG preview made on the phone before upload.
typedef Thumbnail = ({String path, int width, int height});

const _channel = MethodChannel('tedrive/thumbnails');

/// Makes a JPEG thumbnail (at most 320 px on its longest side, the size
/// Telegram accepts) for an image or video. Returns null if the file
/// cannot be decoded; the upload then simply goes without a preview.
Future<Thumbnail?> createThumbnail({
  required String source,
  required String target,
  required bool video,
}) async {
  try {
    final size = await _channel.invokeListMethod<int>('create', {
      'source': source,
      'target': target,
      'video': video,
      'maxSide': 320,
    });
    if (size == null || size.length != 2) return null;
    return (path: target, width: size[0], height: size[1]);
  } on PlatformException {
    return null;
  } on MissingPluginException {
    return null;
  }
}
