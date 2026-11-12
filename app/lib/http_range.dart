import 'dart:math';

/// Parses an HTTP Range header for a resource of [total] bytes.
/// Returns the inclusive (start, end), the whole resource when there is no
/// header, or null when the range cannot be satisfied.
(int, int)? parseRange(String? header, int total) {
  if (total <= 0) return null;
  if (header == null) return (0, total - 1);
  final match = RegExp(r'^bytes=(\d*)-(\d*)$').firstMatch(header.trim());
  if (match == null) return null;
  final first = match.group(1)!;
  final last = match.group(2)!;
  if (first.isEmpty && last.isEmpty) return null;
  if (first.isEmpty) {
    // "bytes=-500": the last 500 bytes.
    final suffix = int.parse(last);
    if (suffix == 0) return null;
    return (max(0, total - suffix), total - 1);
  }
  final start = int.parse(first);
  if (start >= total) return null;
  final end = last.isEmpty ? total - 1 : min(int.parse(last), total - 1);
  if (end < start) return null;
  return (start, end);
}
