// Choosing one person for the photo widget: faces that look alike are
// grouped, the user taps one (for example their own), sees which photos
// it finds, and can make the match closer or looser.

import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../content_index.dart';
import '../drive_controller.dart';
import '../faces.dart';
import '../stored_file.dart';
import 'gallery.dart';

/// Groups faces; a top-level function so that it can run in an isolate.
List<PersonGroup> Function() _grouping(List<FaceRef> faces) =>
    () => groupFaces(faces, threshold: FaceMatch.balanced.threshold);

/// Returns the chosen person, encoded with [encodePerson], or null.
class PersonPickerPage extends StatefulWidget {
  const PersonPickerPage({
    super.key,
    required this.drive,
    required this.contents,
  });

  final DriveController drive;
  final ContentIndex contents;

  @override
  State<PersonPickerPage> createState() => _PersonPickerPageState();
}

class _PersonPickerPageState extends State<PersonPickerPage> {
  List<PersonGroup>? _groups;

  @override
  void initState() {
    super.initState();
    final faces = widget.contents.faces;
    // Comparing thousands of faces takes a moment: off the screen's thread.
    Isolate.run(_grouping(faces))
        .then((g) {
          if (mounted) setState(() => _groups = g);
        })
        .catchError((Object _) {
          if (mounted) setState(() => _groups = const []);
        });
  }

  @override
  Widget build(BuildContext context) {
    final groups = _groups;
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('Choose a person')),
      body: groups == null
          ? const Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  CircularProgressIndicator(),
                  SizedBox(height: 16),
                  Text('Grouping faces…'),
                ],
              ),
            )
          : groups.isEmpty
          ? const Center(
              child: Padding(
                padding: EdgeInsets.all(32),
                child: Text(
                  'No face appears in more than one photo yet. Faces are '
                  'found while TeDrive looks through your photos; try again '
                  'later.',
                  textAlign: TextAlign.center,
                ),
              ),
            )
          : CustomScrollView(
              slivers: [
                SliverToBoxAdapter(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
                    child: Text(
                      'Faces that look alike are grouped. Tap one to see '
                      'its photos. The same person can appear in two groups.',
                      style: theme.textTheme.bodySmall,
                    ),
                  ),
                ),
                SliverPadding(
                  padding: const EdgeInsets.all(12),
                  sliver: SliverGrid.builder(
                    gridDelegate:
                        const SliverGridDelegateWithMaxCrossAxisExtent(
                          maxCrossAxisExtent: 110,
                          mainAxisSpacing: 12,
                          crossAxisSpacing: 12,
                          childAspectRatio: 0.8,
                        ),
                    itemCount: groups.length,
                    itemBuilder: (context, i) {
                      final g = groups[i];
                      return InkWell(
                        borderRadius: BorderRadius.circular(12),
                        onTap: () async {
                          final chosen = await Navigator.of(context)
                              .push<String>(
                                MaterialPageRoute(
                                  builder: (_) => _PersonPage(
                                    drive: widget.drive,
                                    contents: widget.contents,
                                    group: g,
                                  ),
                                ),
                              );
                          if (chosen != null && context.mounted) {
                            Navigator.pop(context, chosen);
                          }
                        },
                        child: Column(
                          children: [
                            Expanded(
                              child: _FaceImage(
                                path: widget.contents.faceImage(g.cover),
                              ),
                            ),
                            const SizedBox(height: 4),
                            Text(
                              '${g.photos.length} photos',
                              style: theme.textTheme.bodySmall,
                            ),
                          ],
                        ),
                      );
                    },
                  ),
                ),
              ],
            ),
    );
  }
}

class _FaceImage extends StatelessWidget {
  const _FaceImage({required this.path});
  final String? path;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final p = path;
    return AspectRatio(
      aspectRatio: 1,
      child: ClipOval(
        child: p == null
            ? ColoredBox(
                color: scheme.secondaryContainer,
                child: Icon(Icons.face, color: scheme.onSecondaryContainer),
              )
            : Image.file(
                File(p),
                fit: BoxFit.cover,
                cacheWidth: 200,
                errorBuilder: (_, _, _) =>
                    ColoredBox(color: scheme.secondaryContainer),
              ),
      ),
    );
  }
}

/// One person's photos, with how close the match must be.
class _PersonPage extends StatefulWidget {
  const _PersonPage({
    required this.drive,
    required this.contents,
    required this.group,
  });

  final DriveController drive;
  final ContentIndex contents;
  final PersonGroup group;

  @override
  State<_PersonPage> createState() => _PersonPageState();
}

class _PersonPageState extends State<_PersonPage> {
  FaceMatch _match = FaceMatch.balanced;

  List<StoredFile> _photos() {
    final Int8List center = widget.group.center;
    return [
      for (final f in widget.drive.files)
        if (f.kind == FileKind.image && !f.isVault)
          if (widget.contents.contentOf(f) case final c?)
            if (showsPerson(c.prints, center, _match)) f,
    ];
  }

  @override
  Widget build(BuildContext context) {
    final photos = _photos();
    return Scaffold(
      appBar: AppBar(
        title: Row(
          children: [
            SizedBox(
              width: 36,
              child: _FaceImage(
                path: widget.contents.faceImage(widget.group.cover),
              ),
            ),
            const SizedBox(width: 12),
            Text('${photos.length} photos'),
          ],
        ),
      ),
      floatingActionButton: photos.isEmpty
          ? null
          : FloatingActionButton.extended(
              icon: const Icon(Icons.widgets_outlined),
              label: const Text('Show in widget'),
              onPressed: () => Navigator.pop(
                context,
                encodePerson(widget.group.center, _match),
              ),
            ),
      body: CustomScrollView(
        slivers: [
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
              child: SegmentedButton<FaceMatch>(
                segments: [
                  for (final m in FaceMatch.values)
                    ButtonSegment(value: m, label: Text(m.label)),
                ],
                selected: {_match},
                onSelectionChanged: (s) => setState(() => _match = s.first),
              ),
            ),
          ),
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 0),
              child: Text(
                'If other people show up, choose Close match. If photos of '
                'this person are missing, choose More photos.',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ),
          ),
          ...gallerySlivers(
            context: context,
            drive: widget.drive,
            files: photos,
            onTap: (_) {},
            onLongPress: (_) {},
          ),
          const SliverToBoxAdapter(child: SizedBox(height: 96)),
        ],
      ),
    );
  }
}
