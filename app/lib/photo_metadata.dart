// Reads where and with what camera a photo was taken, from its EXIF data.

import 'dart:io';

import 'package:exif/exif.dart';

typedef PhotoMetadata = ({
  ({double lat, double lng})? location,
  String? camera,
});

const _photoExtensions = {
  'jpg',
  'jpeg',
  'heic',
  'heif',
  'tif',
  'tiff',
  'png',
  'webp',
};

/// Returns the GPS position and camera model stored in a photo, if any.
/// Only the start of the file is read: EXIF data sits at the front.
Future<PhotoMetadata> readPhotoMetadata(String path) async {
  const none = (location: null, camera: null);
  final ext = path.split('.').last.toLowerCase();
  if (!_photoExtensions.contains(ext)) return none;
  try {
    final file = File(path);
    final length = await file.length();
    final raf = await file.open();
    final List<int> bytes;
    try {
      bytes = await raf.read(length < 512 * 1024 ? length : 512 * 1024);
    } finally {
      await raf.close();
    }
    final tags = await readExifFromBytes(bytes);
    if (tags.isEmpty) return none;
    return (location: gpsFromTags(tags), camera: _camera(tags));
  } catch (_) {
    return none;
  }
}

({double lat, double lng})? gpsFromTags(Map<String, IfdTag> tags) {
  final lat = _degrees(tags['GPS GPSLatitude']);
  final lng = _degrees(tags['GPS GPSLongitude']);
  if (lat == null || lng == null) return null;
  final south =
      tags['GPS GPSLatitudeRef']?.printable.trim().toUpperCase() == 'S';
  final west =
      tags['GPS GPSLongitudeRef']?.printable.trim().toUpperCase() == 'W';
  final la = south ? -lat : lat;
  final ln = west ? -lng : lng;
  // 0,0 is what many phones write when they had no fix.
  if (la.abs() > 90 || ln.abs() > 180 || (la == 0 && ln == 0)) return null;
  return (lat: la, lng: ln);
}

double? _degrees(IfdTag? tag) {
  if (tag == null) return null;
  final values = tag.values.toList();
  if (values.length < 3) return null;
  double part(Object v) => v is Ratio ? v.toDouble() : (v as num).toDouble();
  return part(values[0]) + part(values[1]) / 60 + part(values[2]) / 3600;
}

String? _camera(Map<String, IfdTag> tags) {
  final make = tags['Image Make']?.printable.trim() ?? '';
  final model = tags['Image Model']?.printable.trim() ?? '';
  if (model.isEmpty) return make.isEmpty ? null : make;
  if (make.isEmpty || model.toLowerCase().startsWith(make.toLowerCase())) {
    return model;
  }
  return '$make $model';
}
