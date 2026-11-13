import 'dart:convert';
import 'dart:io';
import 'dart:ui' show ImageFilter;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:flutter/services.dart';

import '../drive_controller.dart';
import '../local_files.dart';
import '../stored_file.dart';

(IconData, Color) kindVisual(FileKind kind) => switch (kind) {
  FileKind.image => (Icons.image_outlined, Colors.teal),
  FileKind.video => (Icons.movie_outlined, Colors.deepPurple),
  FileKind.audio => (Icons.audiotrack_outlined, Colors.orange),
  FileKind.pdf => (Icons.picture_as_pdf_outlined, Colors.red),
  FileKind.document => (Icons.description_outlined, Colors.blue),
  FileKind.archive => (Icons.folder_zip_outlined, Colors.brown),
  FileKind.apk => (Icons.android, Colors.green),
  FileKind.other => (Icons.insert_drive_file_outlined, Colors.blueGrey),
};

/// Round icon for a file type, used in lists.
class KindIcon extends StatelessWidget {
  const KindIcon(this.kind, {super.key});
  final FileKind kind;

  @override
  Widget build(BuildContext context) {
    final (icon, color) = kindVisual(kind);
    return CircleAvatar(
      backgroundColor: color.withValues(alpha: 0.12),
      foregroundColor: color,
      child: Icon(icon),
    );
  }
}

/// A file's preview image: the tiny inline preview first, then the real
/// thumbnail once it has been fetched. Shows [fallback] if there is none.
class FileThumb extends StatefulWidget {
  const FileThumb({
    super.key,
    required this.drive,
    required this.file,
    required this.fallback,
    this.fit = BoxFit.cover,
  });

  final DriveController drive;
  final StoredFile file;
  final Widget fallback;
  final BoxFit fit;

  @override
  State<FileThumb> createState() => _FileThumbState();
}

class _FileThumbState extends State<FileThumb> {
  late Future<String?> _path = widget.drive.thumbnail(widget.file);
  late final _mini = _decodeMini();

  MemoryImage? _decodeMini() {
    final data = widget.file.miniThumb;
    if (data == null || data.isEmpty) return null;
    try {
      return MemoryImage(base64Decode(data));
    } on FormatException {
      return null;
    }
  }

  @override
  void didUpdateWidget(FileThumb old) {
    super.didUpdateWidget(old);
    if (old.file.messageId != widget.file.messageId) {
      _path = widget.drive.thumbnail(widget.file);
    }
  }

  @override
  Widget build(BuildContext context) {
    final placeholder = _mini == null
        ? widget.fallback
        : Image(image: _mini, fit: widget.fit, gaplessPlayback: true);
    if (widget.file.thumbFileId == null) return placeholder;
    return FutureBuilder<String?>(
      future: _path,
      builder: (context, snapshot) {
        final path = snapshot.data;
        if (path == null) return placeholder;
        return localImage(
          path,
          fit: widget.fit,
          cacheWidth: 360,
          gaplessPlayback: true,
          errorBuilder: (_, _, _) => placeholder,
        );
      },
    );
  }
}

/// One square cell of the gallery grid.
class FileGridTile extends StatelessWidget {
  const FileGridTile({
    super.key,
    required this.drive,
    required this.file,
    required this.onTap,
    required this.onLongPress,
    this.selected = false,
    this.selecting = false,
  });

  final DriveController drive;
  final StoredFile file;
  final VoidCallback onTap;
  final VoidCallback onLongPress;

  /// Part of the current multi-selection.
  final bool selected;

  /// A multi-selection is in progress, so every tile shows a check circle.
  final bool selecting;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final (icon, color) = kindVisual(file.kind);
    final downloading = drive.isDownloading(file);
    final isMedia = file.kind == FileKind.image || file.kind == FileKind.video;
    final nameCard = Container(
      color: color.withValues(alpha: 0.10),
      padding: const EdgeInsets.all(6),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(icon, color: color, size: 30),
          const SizedBox(height: 4),
          Text(
            file.name,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            textAlign: TextAlign.center,
            style: theme.textTheme.labelSmall,
          ),
        ],
      ),
    );
    return Semantics(
      label: file.name,
      button: true,
      child: Material(
        clipBehavior: Clip.antiAlias,
        borderRadius: BorderRadius.circular(6),
        child: InkWell(
          onTap: downloading ? null : onTap,
          onLongPress: downloading ? null : onLongPress,
          child: Stack(
            fit: StackFit.expand,
            children: [
              AnimatedPadding(
                duration: const Duration(milliseconds: 120),
                padding: EdgeInsets.all(selected ? 10 : 0),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(selected ? 10 : 0),
                  child: isMedia
                      ? FileThumb(drive: drive, file: file, fallback: nameCard)
                      : nameCard,
                ),
              ),
              if (file.starred)
                const Align(
                  alignment: Alignment.bottomRight,
                  child: Padding(
                    padding: EdgeInsets.all(4),
                    child: _Badge(Icons.star),
                  ),
                ),
              if (selecting)
                Align(
                  alignment: Alignment.topLeft,
                  child: Padding(
                    padding: const EdgeInsets.all(4),
                    child: Icon(
                      selected ? Icons.check_circle : Icons.circle_outlined,
                      color: selected
                          ? theme.colorScheme.primary
                          : Colors.white,
                      shadows: const [Shadow(blurRadius: 4)],
                    ),
                  ),
                ),
              if (file.kind == FileKind.video)
                const Align(
                  alignment: Alignment.bottomLeft,
                  child: Padding(
                    padding: EdgeInsets.all(4),
                    child: _Badge(Icons.play_arrow),
                  ),
                ),
              if (file.localPath != null)
                const Align(
                  alignment: Alignment.topRight,
                  child: Padding(
                    padding: EdgeInsets.all(4),
                    child: _Badge(Icons.offline_pin),
                  ),
                ),
              if (downloading)
                ColoredBox(
                  color: Colors.black45,
                  child: Center(
                    child: CircularProgressIndicator(
                      value: drive.downloads[file.messageId],
                      color: Colors.white,
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Badge extends StatelessWidget {
  const _Badge(this.icon);
  final IconData icon;

  @override
  Widget build(BuildContext context) => DecoratedBox(
    decoration: const BoxDecoration(
      color: Colors.black54,
      shape: BoxShape.circle,
    ),
    child: Padding(
      padding: const EdgeInsets.all(2),
      child: Icon(icon, size: 14, color: Colors.white),
    ),
  );
}

/// Slivers for the grid view: one titled section per day.
List<Widget> gallerySlivers({
  required BuildContext context,
  required DriveController drive,
  required List<StoredFile> files,
  required void Function(StoredFile) onTap,
  required void Function(StoredFile) onLongPress,
  bool Function(StoredFile)? isSelected,
}) {
  final selecting = isSelected != null;
  final theme = Theme.of(context);
  return [
    for (final group in groupByDay(files)) ...[
      SliverToBoxAdapter(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
          child: Text(group.label, style: theme.textTheme.titleSmall),
        ),
      ),
      SliverPadding(
        padding: const EdgeInsets.symmetric(horizontal: 8),
        sliver: SliverGrid.builder(
          gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
            maxCrossAxisExtent: 130,
            mainAxisSpacing: 4,
            crossAxisSpacing: 4,
          ),
          itemCount: group.files.length,
          itemBuilder: (context, i) {
            final file = group.files[i];
            return FileGridTile(
              key: ValueKey(file.messageId),
              drive: drive,
              file: file,
              onTap: () => onTap(file),
              onLongPress: () => onLongPress(file),
              selecting: selecting,
              selected: isSelected?.call(file) ?? false,
            );
          },
        ),
      ),
    ],
  ];
}

/// Full-screen, swipeable, zoomable viewer for the images in [files].
class ImageViewerPage extends StatefulWidget {
  const ImageViewerPage({
    super.key,
    required this.drive,
    required this.files,
    required this.initialIndex,
    required this.onShare,
    required this.onMore,
  });

  final DriveController drive;
  final List<StoredFile> files;
  final int initialIndex;
  final void Function(StoredFile) onShare;
  final void Function(StoredFile) onMore;

  @override
  State<ImageViewerPage> createState() => _ImageViewerPageState();
}

class _ImageViewerPageState extends State<ImageViewerPage> {
  late final _pages = PageController(initialPage: widget.initialIndex);
  late int _index = widget.initialIndex;

  @override
  void initState() {
    super.initState();
    _prefetch(_index);
  }

  @override
  void dispose() {
    _pages.dispose();
    super.dispose();
  }

  /// Starts downloading the photos either side, so swiping is instant.
  /// Only on Wi-Fi: on mobile data nothing downloads unless asked for.
  Future<void> _prefetch(int i) async {
    // Nothing is fetched ahead: originals download only when asked for.
    if (i >= 0) return;
    for (final n in [i + 1, i - 1]) {
      if (n < 0 || n >= widget.files.length) continue;
      final f = widget.files[n];
      if (f.kind == FileKind.image && !widget.drive.isDownloading(f)) {
        widget.drive
            .ensureLocal(f, background: true)
            .then((_) {}, onError: (_) {});
      }
    }
  }

  void _go(int delta) {
    final next = _index + delta;
    if (next < 0 || next >= widget.files.length) return;
    _pages.animateToPage(
      next,
      duration: const Duration(milliseconds: 250),
      curve: Curves.easeOut,
    );
  }

  @override
  Widget build(BuildContext context) {
    final file = widget.files[_index];
    final wide = MediaQuery.sizeOf(context).width >= 700;
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              file.name,
              style: const TextStyle(fontSize: 16),
              overflow: TextOverflow.ellipsis,
            ),
            Text(
              '${formatDate(file.date)} · ${formatBytes(file.size)}',
              style: const TextStyle(fontSize: 12, color: Colors.white70),
            ),
          ],
        ),
        actions: [
          IconButton(
            tooltip: 'Details & location',
            icon: const Icon(Icons.info_outline),
            onPressed: () => _showDetails(context, file),
          ),
          IconButton(
            tooltip: 'Share or send',
            icon: const Icon(Icons.share_outlined),
            onPressed: () => widget.onShare(file),
          ),
          IconButton(
            tooltip: 'More actions',
            icon: const Icon(Icons.more_vert),
            onPressed: () => widget.onMore(file),
          ),
        ],
      ),
      body: CallbackShortcuts(
        bindings: {
          const SingleActivator(LogicalKeyboardKey.arrowRight): () => _go(1),
          const SingleActivator(LogicalKeyboardKey.arrowLeft): () => _go(-1),
          const SingleActivator(LogicalKeyboardKey.escape): () =>
              Navigator.maybePop(context),
        },
        child: Focus(
          autofocus: true,
          child: Stack(
            children: [
              PageView.builder(
                controller: _pages,
                itemCount: widget.files.length,
                onPageChanged: (i) {
                  setState(() => _index = i);
                  _prefetch(i);
                },
                itemBuilder: (context, i) => _FullImage(
                  key: ValueKey(widget.files[i].messageId),
                  drive: widget.drive,
                  file: widget.files[i],
                ),
              ),
              if (wide && _index > 0)
                Align(
                  alignment: Alignment.centerLeft,
                  child: _NavButton(
                    icon: Icons.chevron_left,
                    tooltip: 'Previous',
                    onPressed: () => _go(-1),
                  ),
                ),
              if (wide && _index < widget.files.length - 1)
                Align(
                  alignment: Alignment.centerRight,
                  child: _NavButton(
                    icon: Icons.chevron_right,
                    tooltip: 'Next',
                    onPressed: () => _go(1),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  void _showDetails(BuildContext context, StoredFile file) {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => _PhotoDetailsSheet(drive: widget.drive, file: file),
    );
  }
}

class _PhotoDetailsSheet extends StatelessWidget {
  const _PhotoDetailsSheet({required this.drive, required this.file});
  final DriveController drive;
  final StoredFile file;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final loc = file.location;

    return SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    'Photo Details',
                    style: theme.textTheme.titleLarge?.copyWith(
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
                if (file.isVault)
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 4,
                    ),
                    decoration: BoxDecoration(
                      color: scheme.primaryContainer,
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          Icons.lock_rounded,
                          size: 14,
                          color: scheme.onPrimaryContainer,
                        ),
                        const SizedBox(width: 4),
                        Text(
                          'Encrypted Vault',
                          style: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                            color: scheme.onPrimaryContainer,
                          ),
                        ),
                      ],
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 16),
            _infoRow(
              context,
              Icons.insert_drive_file_outlined,
              'File name',
              file.name,
            ),
            _infoRow(
              context,
              Icons.data_usage_outlined,
              'Size',
              formatBytes(file.size),
            ),
            _infoRow(
              context,
              Icons.calendar_today_outlined,
              file.taken != null ? 'Date captured' : 'Date uploaded',
              formatDate(file.date),
            ),
            if (file.folder != null)
              _infoRow(context, Icons.folder_outlined, 'Album', file.folder!),
            if (file.camera != null && file.camera!.isNotEmpty)
              _infoRow(
                context,
                Icons.camera_alt_outlined,
                'Camera',
                file.camera!,
              ),
            if (file.device != null)
              _infoRow(
                context,
                Icons.devices_outlined,
                'Uploaded from',
                file.device!,
              ),

            // Map section
            if (loc != null) ...[
              const Divider(height: 32),
              Row(
                children: [
                  Icon(Icons.location_on_outlined, color: scheme.primary),
                  const SizedBox(width: 8),
                  Text(
                    'Location',
                    style: theme.textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const Spacer(),
                  Text(
                    '${loc.lat.toStringAsFixed(4)}, ${loc.lng.toStringAsFixed(4)}',
                    style: theme.textTheme.bodySmall?.copyWith(
                      fontFamily: 'monospace',
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              SizedBox(
                height: 180,
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(16),
                  child: FlutterMap(
                    options: MapOptions(
                      initialCenter: LatLng(loc.lat, loc.lng),
                      initialZoom: 14,
                    ),
                    children: [
                      TileLayer(
                        urlTemplate:
                            'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                        userAgentPackageName: 'dev.tedrive.tedrive',
                      ),
                      MarkerLayer(
                        markers: [
                          Marker(
                            point: LatLng(loc.lat, loc.lng),
                            width: 40,
                            height: 40,
                            alignment: Alignment.topCenter,
                            child: Icon(
                              Icons.location_pin,
                              color: scheme.error,
                              size: 40,
                            ),
                          ),
                        ],
                      ),
                      const SimpleAttributionWidget(
                        source: Text('OpenStreetMap contributors'),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 12),
              SizedBox(
                width: double.infinity,
                child: FilledButton.tonalIcon(
                  icon: const Icon(Icons.map_outlined),
                  label: const Text('Open in Maps'),
                  onPressed: () {
                    final url =
                        'https://www.google.com/maps/search/?api=1&query=${loc.lat},${loc.lng}';
                    Clipboard.setData(ClipboardData(text: url));
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(
                        content: Text('Maps link copied to clipboard'),
                      ),
                    );
                  },
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _infoRow(
    BuildContext context,
    IconData icon,
    String label,
    String value,
  ) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 20, color: theme.colorScheme.onSurfaceVariant),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  label,
                  style: TextStyle(
                    fontSize: 12,
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
                Text(
                  value,
                  style: const TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _FullImage extends StatefulWidget {
  const _FullImage({super.key, required this.drive, required this.file});
  final DriveController drive;
  final StoredFile file;

  @override
  State<_FullImage> createState() => _FullImageState();
}

class _FullImageState extends State<_FullImage> {
  String? _path;
  String? _error;

  /// On mobile data the full photo waits for a tap (data saver).
  bool _waiting = false;

  @override
  void initState() {
    super.initState();
    _start();
  }

  Future<void> _start() async {
    final local = widget.file.localPath;
    if (!localExists(local) && !widget.drive.isDownloading(widget.file)) {
      if (mounted) setState(() => _waiting = true);
      return;
    }
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _error = null;
      _waiting = false;
    });
    try {
      final path = await widget.drive.ensureLocal(widget.file);
      if (mounted) setState(() => _path = path);
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    }
  }

  @override
  Widget build(BuildContext context) {
    const broken = Icon(
      Icons.broken_image_outlined,
      color: Colors.white54,
      size: 64,
    );
    final path = _path;
    if (path != null) {
      return InteractiveViewer(
        maxScale: 6,
        child: Center(
          child: localImage(
            path,
            fit: BoxFit.contain,
            gaplessPlayback: true,
            filterQuality: FilterQuality.high,
            frameBuilder: (context, child, frame, sync) => sync
                ? child
                : AnimatedOpacity(
                    opacity: frame == null ? 0 : 1,
                    duration: const Duration(milliseconds: 250),
                    child: child,
                  ),
            errorBuilder: (_, _, _) => const Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                broken,
                SizedBox(height: 12),
                Text(
                  'This image format cannot be shown here.\n'
                  'Use the menu to open it in another app.',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: Colors.white70),
                ),
              ],
            ),
          ),
        ),
      );
    }
    if (_waiting) {
      return Stack(
        fit: StackFit.expand,
        children: [
          FileThumb(
            drive: widget.drive,
            file: widget.file,
            fit: BoxFit.contain,
            fallback: const SizedBox.shrink(),
          ),
          Align(
            alignment: const Alignment(0, 0.85),
            child: FilledButton.tonalIcon(
              icon: const Icon(Icons.hd_outlined),
              label: Text('Load original · ${formatBytes(widget.file.size)}'),
              onPressed: _load,
            ),
          ),
        ],
      );
    }
    return Stack(
      fit: StackFit.expand,
      children: [
        // The small preview fills in, softly blurred, while the full image
        // downloads, so it does not look pixelated.
        ImageFiltered(
          imageFilter: ImageFilter.blur(sigmaX: 8, sigmaY: 8),
          child: FileThumb(
            drive: widget.drive,
            file: widget.file,
            fit: BoxFit.contain,
            fallback: const SizedBox.shrink(),
          ),
        ),
        Center(
          child: _error == null
              ? ListenableBuilder(
                  listenable: widget.drive,
                  builder: (context, _) {
                    final p = widget.drive.downloads[widget.file.messageId];
                    return Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 18,
                        vertical: 12,
                      ),
                      decoration: BoxDecoration(
                        color: Colors.black54,
                        borderRadius: BorderRadius.circular(24),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          SizedBox.square(
                            dimension: 20,
                            child: CircularProgressIndicator(
                              value: p,
                              strokeWidth: 2.5,
                              color: Colors.white,
                            ),
                          ),
                          const SizedBox(width: 12),
                          Text(
                            p == null
                                ? 'Loading full image…'
                                : 'Loading ${(p * 100).round()}%',
                            style: const TextStyle(color: Colors.white),
                          ),
                        ],
                      ),
                    );
                  },
                )
              : Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    broken,
                    const SizedBox(height: 12),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 32),
                      child: Text(
                        _error!,
                        textAlign: TextAlign.center,
                        style: const TextStyle(color: Colors.white70),
                      ),
                    ),
                    TextButton(
                      onPressed: _load,
                      child: const Text('Try again'),
                    ),
                  ],
                ),
        ),
      ],
    );
  }
}

/// An image from a downloaded copy: a file on phones and computers, a
/// blob: URL in the browser.
Widget localImage(
  String path, {
  BoxFit? fit,
  int? cacheWidth,
  bool gaplessPlayback = false,
  FilterQuality filterQuality = FilterQuality.medium,
  ImageFrameBuilder? frameBuilder,
  ImageErrorWidgetBuilder? errorBuilder,
}) => kIsWeb
    ? Image.network(
        path,
        fit: fit,
        cacheWidth: cacheWidth,
        gaplessPlayback: gaplessPlayback,
        filterQuality: filterQuality,
        frameBuilder: frameBuilder,
        errorBuilder: errorBuilder,
      )
    : Image.file(
        File(path),
        fit: fit,
        cacheWidth: cacheWidth,
        gaplessPlayback: gaplessPlayback,
        filterQuality: filterQuality,
        frameBuilder: frameBuilder,
        errorBuilder: errorBuilder,
      );

class _NavButton extends StatelessWidget {
  const _NavButton({
    required this.icon,
    required this.tooltip,
    required this.onPressed,
  });
  final IconData icon;
  final String tooltip;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.all(12),
    child: IconButton.filledTonal(
      tooltip: tooltip,
      iconSize: 32,
      style: IconButton.styleFrom(
        backgroundColor: Colors.black45,
        foregroundColor: Colors.white,
      ),
      icon: Icon(icon),
      onPressed: onPressed,
    ),
  );
}
