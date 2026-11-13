// Check for updates: compares this build with the latest GitHub release and,
// on Android, downloads the new APK and hands it to the system installer.
// The new APK is signed with the same key, so it installs over the old one
// and keeps every setting, the sign-in and the downloaded files.

import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';

import 'config.dart';
import 'device.dart' as device;
import 'version.dart';

const _releasesApi =
    'https://api.github.com/repos/nitheeshmk41/TeDrive/releases/latest';
const releasesPage = 'https://github.com/nitheeshmk41/TeDrive/releases/latest';

class AppRelease {
  AppRelease(this.tag, this.notes, this.assets);
  final String tag;
  final String notes;
  final Map<String, String> assets; // file name -> download URL

  /// The APK for this phone's processor.
  String? get apkUrl {
    final arm32 = Platform.version.contains('android_arm"');
    final want = arm32 ? 'android-arm32' : 'android-arm64';
    for (final e in assets.entries) {
      if (e.key.contains(want) && e.key.endsWith('.apk')) return e.value;
    }
    return null;
  }
}

/// The latest release, or null if it cannot be reached.
Future<AppRelease?> fetchLatestRelease() async {
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 15);
  try {
    final req = await client.getUrl(Uri.parse(_releasesApi));
    req.headers.set('Accept', 'application/vnd.github+json');
    req.headers.set('User-Agent', 'TeDrive-app');
    final res = await req.close();
    if (res.statusCode != 200) return null;
    final json = jsonDecode(
      await res.transform(utf8.decoder).join(),
    ) as Map<String, dynamic>;
    return AppRelease(
      json['tag_name'] as String? ?? '',
      json['body'] as String? ?? '',
      {
        for (final a in (json['assets'] as List? ?? const []))
          a['name'] as String: a['browser_download_url'] as String,
      },
    );
  } catch (_) {
    return null;
  } finally {
    client.close();
  }
}

const _site = 'https://tedrive.vercel.app/download';

/// The latest release according to the TeDrive site, used when GitHub's
/// API refuses (it limits requests per network address).
Future<AppRelease?> _fetchFromSite() async {
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 15);
  try {
    final res = await (await client.getUrl(Uri.parse('$_site/version.txt')))
        .close();
    if (res.statusCode != 200) return null;
    final tag = (await res.transform(utf8.decoder).join()).trim();
    if (!RegExp(r'^v\d').hasMatch(tag)) return null;
    return AppRelease(tag, '', {
      'TeDrive-android-arm64.apk': '$_site/TeDrive-android-arm64.apk',
      'TeDrive-android-arm32.apk': '$_site/TeDrive-android-arm32.apk',
    });
  } catch (_) {
    return null;
  } finally {
    client.close();
  }
}

/// The newest release either source knows about.
Future<AppRelease?> latestRelease() async {
  final results = await Future.wait([fetchLatestRelease(), _fetchFromSite()]);
  final github = results[0], site = results[1];
  if (github == null) return site;
  if (site != null && isNewer(site.tag, github.tag)) return site;
  return github;
}

/// Checks once when the app starts and offers the update in a snack bar.
Future<void> checkForUpdateQuietly(BuildContext context) async {
  if (kIsWeb) return;
  final release = await latestRelease();
  if (release == null || !isNewer(release.tag, appVersion)) return;
  if (!context.mounted) return;
  final messenger = ScaffoldMessenger.of(context);
  messenger.showMaterialBanner(
    MaterialBanner(
      leading: const Icon(Icons.system_update_outlined),
      content: Text(
        'TeDrive ${release.tag} is available. You have v$appVersion.',
      ),
      actions: [
        TextButton(
          onPressed: messenger.hideCurrentMaterialBanner,
          child: const Text('Later'),
        ),
        FilledButton(
          onPressed: () {
            messenger.hideCurrentMaterialBanner();
            showUpdateDialog(context, release: release);
          },
          child: const Text('Update'),
        ),
      ],
    ),
  );
}

/// The "Check for updates" dialog.
Future<void> showUpdateDialog(BuildContext context, {AppRelease? release}) {
  return showDialog<void>(
    context: context,
    builder: (_) => _UpdateDialog(release: release),
  );
}

class _UpdateDialog extends StatefulWidget {
  const _UpdateDialog({this.release});
  final AppRelease? release;

  @override
  State<_UpdateDialog> createState() => _UpdateDialogState();
}

class _UpdateDialogState extends State<_UpdateDialog> {
  AppRelease? _release;
  bool _checking = true;
  double? _progress; // null while not downloading
  String? _error;

  @override
  void initState() {
    super.initState();
    _release = widget.release;
    if (_release != null) {
      _checking = false;
    } else {
      latestRelease().then((r) {
        if (!mounted) return;
        setState(() {
          _release = r;
          _checking = false;
          if (r == null) _error = 'Could not check. Check your connection.';
        });
      });
    }
  }

  bool get _hasUpdate => _release != null && isNewer(_release!.tag, appVersion);

  Future<void> _install() async {
    final release = _release!;
    if (!device.isAndroid) {
      _openInBrowser(releasesPage);
      if (mounted) Navigator.pop(context);
      return;
    }
    final url = release.apkUrl;
    if (url == null) {
      setState(() => _error = 'This release has no APK for this phone.');
      return;
    }
    setState(() {
      _progress = 0;
      _error = null;
    });
    final client = HttpClient();
    try {
      final dir = await getTemporaryDirectory();
      final file = File('${dir.path}/TeDrive-update.apk');
      final res = await (await client.getUrl(Uri.parse(url))).close();
      if (res.statusCode != 200) throw HttpException('HTTP ${res.statusCode}');
      final total = res.contentLength;
      var done = 0;
      final sink = file.openWrite();
      await for (final chunk in res) {
        sink.add(chunk);
        done += chunk.length;
        if (total > 0 && mounted) setState(() => _progress = done / total);
      }
      await sink.close();
      final opened = await device.openFile(
        file.path,
        mime: 'application/vnd.android.package-archive',
      );
      if (!opened) throw const FileSystemException('No installer');
      if (mounted) Navigator.pop(context);
    } catch (_) {
      if (mounted) {
        setState(() {
          _progress = null;
          _error =
              'Download failed. You can also get it from the releases page.';
        });
      }
    } finally {
      client.close();
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final Widget body;
    if (_checking) {
      body = const Row(
        children: [
          SizedBox(
            width: 20,
            height: 20,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
          SizedBox(width: 16),
          Text('Checking for updates…'),
        ],
      );
    } else if (_progress != null) {
      body = Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          LinearProgressIndicator(value: _progress == 0 ? null : _progress),
          const SizedBox(height: 12),
          Text(
            'Downloading ${_release!.tag}… ${((_progress ?? 0) * 100).round()}%',
          ),
        ],
      );
    } else if (_hasUpdate) {
      body = Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Version ${_release!.tag} is available. You have v$appVersion.',
            style: theme.textTheme.bodyLarge,
          ),
          const SizedBox(height: 8),
          Text(
            device.isAndroid
                ? 'It installs over this version. Your sign-in, files and settings stay.'
                : 'Download it from the releases page and replace this copy.',
            style: theme.textTheme.bodySmall,
          ),
          if (_error != null) ...[
            const SizedBox(height: 8),
            Text(_error!, style: TextStyle(color: theme.colorScheme.error)),
          ],
        ],
      );
    } else {
      body = Text(_error ?? 'You have the latest version (v$appVersion).');
    }
    return AlertDialog(
      title: const Text('Check for updates'),
      content: body,
      actions: [
        if (_progress == null)
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(_hasUpdate ? 'Later' : 'Close'),
          ),
        if (_hasUpdate && _progress == null)
          FilledButton(
            onPressed: _install,
            child: Text(
              device.isAndroid ? 'Download and install' : 'Open download page',
            ),
          ),
      ],
    );
  }
}

void _openInBrowser(String url) {
  try {
    if (Platform.isWindows) {
      Process.run('rundll32', ['url.dll,FileProtocolHandler', url]);
    } else if (Platform.isMacOS) {
      Process.run('open', [url]);
    } else {
      Process.run('xdg-open', [url]);
    }
  } catch (_) {}
}
