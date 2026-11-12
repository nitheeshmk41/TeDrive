import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../drive_controller.dart';
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
  void dispose() {
    _pages.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final file = widget.files[_index];
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
      body: PageView.builder(
        controller: _pages,
        itemCount: widget.files.length,
        onPageChanged: (i) => setState(() => _index = i),
        itemBuilder: (context, i) => _FullImage(
          key: ValueKey(widget.files[i].messageId),
          drive: widget.drive,
          file: widget.files[i],
        ),
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

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _error = null);
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
    return Stack(
      fit: StackFit.expand,
      children: [
        // The small preview fills in while the full image downloads.
        FileThumb(
          drive: widget.drive,
          file: widget.file,
          fit: BoxFit.contain,
          fallback: const SizedBox.shrink(),
        ),
        Center(
          child: _error == null
              ? ListenableBuilder(
                  listenable: widget.drive,
                  builder: (context, _) => CircularProgressIndicator(
                    value: widget.drive.downloads[widget.file.messageId],
                    color: Colors.white,
                  ),
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
  ImageErrorWidgetBuilder? errorBuilder,
}) => kIsWeb
    ? Image.network(
        path,
        fit: fit,
        cacheWidth: cacheWidth,
        gaplessPlayback: gaplessPlayback,
        errorBuilder: errorBuilder,
      )
    : Image.file(
        File(path),
        fit: fit,
        cacheWidth: cacheWidth,
        gaplessPlayback: gaplessPlayback,
        errorBuilder: errorBuilder,
      );
