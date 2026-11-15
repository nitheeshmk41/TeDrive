// Check for updates: compares this build with the latest GitHub release and,
// on Android, downloads the new APK and hands it to the system installer.
// The new APK is signed with the same key, so it installs over the old one
// and keeps every setting, the sign-in and the downloaded files.

import 'dart:async';
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
    final res = await (await client.getUrl(
      Uri.parse(
        '$_site/version.txt?t=${DateTime.now().millisecondsSinceEpoch}',
      ),
    )).close();
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
  final downloaded = await device.updateStatus();
  if (downloaded.state == 'ready' &&
      isNewer(downloaded.tag ?? '', appVersion) &&
      context.mounted) {
    showUpdateReadyBanner(context, downloaded.tag!);
    return;
  }
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

/// A background download finished: offer to install it.
void showUpdateReadyBanner(BuildContext context, String tag) {
  final messenger = ScaffoldMessenger.of(context);
  messenger.hideCurrentMaterialBanner();
  messenger.showMaterialBanner(
    MaterialBanner(
      leading: const Icon(Icons.system_update_outlined),
      content: Text(
        'TeDrive $tag is downloaded and ready to install. Android closes '
        'TeDrive for a few seconds while it installs; everything stays.',
      ),
      actions: [
        TextButton(
          onPressed: messenger.hideCurrentMaterialBanner,
          child: const Text('Later'),
        ),
        FilledButton(
          onPressed: () {
            messenger.hideCurrentMaterialBanner();
            device.installUpdate();
          },
          child: const Text('Install now'),
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

  /// Set when the new APK has a different signing key: where it was saved.
  String? _conflictApk;

  /// Downloading with Android's download manager, which carries on when
  /// TeDrive is closed.
  bool _background = false;

  /// The update is downloaded and checked.
  bool _ready = false;
  Timer? _poll;

  @override
  void dispose() {
    _poll?.cancel();
    super.dispose();
  }

  /// Follows the background download until it is ready or fails.
  void _follow() {
    _poll?.cancel();
    _poll = Timer.periodic(const Duration(milliseconds: 700), (_) async {
      final s = await device.updateStatus();
      if (!mounted) return;
      switch (s.state) {
        case 'running':
          setState(() => _progress = s.total > 0 ? s.done / s.total : 0);
        case 'ready':
          _poll?.cancel();
          setState(() {
            _progress = null;
            _ready = true;
          });
        case 'conflict':
          _poll?.cancel();
          final saved = s.path == null
              ? null
              : await device.saveToDownloads(
                  s.path!,
                  name: 'TeDrive-${s.tag}.apk',
                  mime: 'application/vnd.android.package-archive',
                );
          if (mounted) {
            setState(() {
              _progress = null;
              _background = false;
              _conflictApk = saved ?? '';
            });
          }
        default:
          // Failed or gone: download inside the app instead.
          _poll?.cancel();
          setState(() => _background = false);
          _download(useBackground: false);
      }
    });
  }

  @override
  void initState() {
    super.initState();
    _release = widget.release;
    // A download already under way or finished, from earlier.
    device.updateStatus().then((s) {
      if (!mounted || !isNewer(s.tag ?? '', appVersion)) return;
      if (s.state == 'running') {
        setState(() {
          _background = true;
          _progress = 0;
        });
        _follow();
      } else if (s.state == 'ready') {
        setState(() => _ready = true);
      }
    });
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

  Future<void> _install() => _download(useBackground: true);

  Future<void> _download({required bool useBackground}) async {
    final release = _release!;
    if (!device.isAndroid) {
      await device.openLink(releasesPage);
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
    if (useBackground && await device.startUpdateDownload(url, release.tag)) {
      if (!mounted) return;
      setState(() => _background = true);
      _follow();
      return;
    }
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
      if (await device.apkMatchesInstalled(file.path) == false) {
        // Android would refuse it ("package conflicts"). Keep the APK where
        // the user can find it after uninstalling.
        final saved = await device.saveToDownloads(
          file.path,
          name: 'TeDrive-${release.tag}.apk',
          mime: 'application/vnd.android.package-archive',
        );
        if (mounted) {
          setState(() {
            _progress = null;
            _conflictApk = saved ?? '';
          });
        }
        return;
      }
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
    } else if (_ready) {
      body = Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Ready to install', style: theme.textTheme.titleMedium),
          const SizedBox(height: 8),
          const Text(
            'Tap Install now, then Update. Android closes TeDrive for a few '
            'seconds while it installs: that is normal. Do not close the '
            'installer until it says the app is installed, then tap Open.',
          ),
          const SizedBox(height: 8),
          Text(
            'Your sign-in, files and settings stay.',
            style: theme.textTheme.bodySmall,
          ),
        ],
      );
    } else if (_progress != null) {
      body = Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          LinearProgressIndicator(value: _progress == 0 ? null : _progress),
          const SizedBox(height: 12),
          Text(
            'Downloading ${_release?.tag ?? 'the update'}… '
            '${((_progress ?? 0) * 100).round()}%',
          ),
          const SizedBox(height: 8),
          Text(
            _background
                ? 'This carries on in the background. You can close this '
                      'window, use TeDrive or leave it; a notification '
                      'tells you when it is ready to install.'
                : 'Please keep TeDrive open until the download finishes.',
            style: theme.textTheme.bodySmall,
          ),
        ],
      );
    } else if (_conflictApk != null) {
      body = Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'This update needs a fresh install',
            style: theme.textTheme.titleMedium,
          ),
          const SizedBox(height: 8),
          const Text(
            'The TeDrive on this phone was signed with an older key, so '
            'Android will not install the new version over it. This is '
            'needed only once.',
          ),
          const SizedBox(height: 12),
          Text(
            _conflictApk!.isEmpty
                ? '1. Uninstall TeDrive.\n'
                      '2. Download the new version from the releases page '
                      'and install it.\n'
                      '3. Sign in again.'
                : '1. The new version is saved as $_conflictApk.\n'
                      '2. Uninstall TeDrive.\n'
                      '3. Open that file from your Files app to install it.\n'
                      '4. Sign in again.',
          ),
          const SizedBox(height: 12),
          Text(
            'Your files are safe: they are in your Telegram account, not '
            'in the app.',
            style: theme.textTheme.bodySmall,
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
                ? 'It installs over this version. Your sign-in, files and '
                      'settings stay. TeDrive closes while Android installs '
                      'it; tap Open at the end, or the "TeDrive updated" '
                      'notification.'
                : 'Download it from the releases page and replace this copy.',
            style: theme.textTheme.bodySmall,
          ),
          if (_release!.notes.trim().isNotEmpty) ...[
            const SizedBox(height: 12),
            Text("What's new", style: theme.textTheme.titleSmall),
            const SizedBox(height: 4),
            ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 220),
              child: SingleChildScrollView(
                child: Text(
                  _release!.notes.trim(),
                  style: theme.textTheme.bodySmall,
                ),
              ),
            ),
          ],
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
        if (_progress == null && !_checking && (_error != null || !_hasUpdate))
          TextButton(
            onPressed: () => device.openLink(releasesPage),
            child: const Text('Releases page'),
          ),
        if (_progress == null || _background)
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(
              _background && !_ready
                  ? 'Hide'
                  : _hasUpdate || _ready
                  ? 'Later'
                  : 'Close',
            ),
          ),
        if (_ready)
          FilledButton(
            onPressed: () async {
              if (!await device.installUpdate() && mounted) {
                setState(() {
                  _ready = false;
                  _error = 'Could not open the installer.';
                });
              }
            },
            child: const Text('Install now'),
          )
        else if (_conflictApk != null)
          FilledButton(
            onPressed: device.uninstallSelf,
            child: const Text('Uninstall TeDrive'),
          )
        else if (_hasUpdate && _progress == null)
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
