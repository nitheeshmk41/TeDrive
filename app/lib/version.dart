// Version numbers of TeDrive releases, kept free of Flutter so tests can use it.

/// "v2.1.0", "v2-lts" or "2.1" -> [2, 1, 0]. Text after the numbers is ignored.
List<int> parseVersion(String text) {
  final m = RegExp(r'(\d+)(?:\.(\d+))?(?:\.(\d+))?').firstMatch(text);
  if (m == null) return const [0, 0, 0];
  return [for (var i = 1; i <= 3; i++) int.tryParse(m.group(i) ?? '0') ?? 0];
}

/// True if [latest] is a newer version than [current].
bool isNewer(String latest, String current) {
  final a = parseVersion(latest), b = parseVersion(current);
  for (var i = 0; i < 3; i++) {
    if (a[i] != b[i]) return a[i] > b[i];
  }
  return false;
}
