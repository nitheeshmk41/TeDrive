import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';

import '../drive_controller.dart';
import '../stored_file.dart';
import 'gallery.dart';

/// Plays a video or audio file inside the app. A file that is not on the
/// phone is streamed from Telegram, so playback starts without waiting for
/// the whole download.
class PlayerPage extends StatefulWidget {
  const PlayerPage({
    super.key,
    required this.drive,
    required this.file,
    required this.onShare,
    required this.onMore,
    required this.onOpenElsewhere,
  });

  final DriveController drive;
  final StoredFile file;
  final void Function(StoredFile) onShare;
  final void Function(StoredFile) onMore;

  /// Fallback when this phone cannot play the format.
  final void Function(StoredFile) onOpenElsewhere;

  @override
  State<PlayerPage> createState() => _PlayerPageState();
}

class _PlayerPageState extends State<PlayerPage> {
  VideoPlayerController? _player;
  String? _error;
  bool _controlsVisible = true;

  bool get _isAudio => widget.file.kind == FileKind.audio;

  @override
  void initState() {
    super.initState();
    _start();
  }

  Future<void> _start() async {
    try {
      final local = widget.file.localPath;
      final VideoPlayerController player;
      if (!kIsWeb && local != null && File(local).existsSync()) {
        player = VideoPlayerController.file(File(local));
      } else {
        player = VideoPlayerController.networkUrl(
          await widget.drive.streamUrl(widget.file),
        );
      }
      _player = player;
      player.addListener(_onTick);
      await player.initialize();
      if (!mounted) return;
      await player.play();
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    }
  }

  void _onTick() {
    if (!mounted) return;
    final error = _player?.value.errorDescription;
    setState(() {
      if (error != null) _error = error;
    });
  }

  @override
  void dispose() {
    _player?.removeListener(_onTick);
    _player?.dispose();
    super.dispose();
  }

  void _seekBy(Duration delta) {
    final player = _player;
    if (player == null) return;
    final target = player.value.position + delta;
    final end = player.value.duration;
    player.seekTo(
      target < Duration.zero
          ? Duration.zero
          : target > end
          ? end
          : target,
    );
  }

  static String _clock(Duration d) {
    String two(int v) => v.toString().padLeft(2, '0');
    final h = d.inHours;
    final m = d.inMinutes.remainder(60);
    final s = d.inSeconds.remainder(60);
    return h > 0 ? '$h:${two(m)}:${two(s)}' : '$m:${two(s)}';
  }

  @override
  Widget build(BuildContext context) {
    final file = widget.file;
    final player = _player;
    final ready = player != null && player.value.isInitialized;
    return Scaffold(
      backgroundColor: Colors.black,
      extendBodyBehindAppBar: true,
      appBar: _controlsVisible || !ready || _isAudio
          ? AppBar(
              backgroundColor: Colors.black54,
              foregroundColor: Colors.white,
              title: Text(
                file.name,
                style: const TextStyle(fontSize: 16, color: Colors.white),
                overflow: TextOverflow.ellipsis,
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
            )
          : null,
      body: _error != null
          ? _PlaybackError(
              message: _error!,
              onOpenElsewhere: () => widget.onOpenElsewhere(file),
            )
          : GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () => setState(() => _controlsVisible = !_controlsVisible),
              child: Stack(
                fit: StackFit.expand,
                children: [
                  if (_isAudio || !ready)
                    Center(
                      child: _isAudio
                          ? const Icon(
                              Icons.graphic_eq,
                              size: 120,
                              color: Colors.white54,
                            )
                          : FileThumb(
                              drive: widget.drive,
                              file: file,
                              fit: BoxFit.contain,
                              fallback: const SizedBox.shrink(),
                            ),
                    ),
                  if (ready && !_isAudio)
                    Center(
                      child: AspectRatio(
                        aspectRatio: player.value.aspectRatio == 0
                            ? 16 / 9
                            : player.value.aspectRatio,
                        child: VideoPlayer(player),
                      ),
                    ),
                  if (!ready || player.value.isBuffering)
                    const Center(
                      child: CircularProgressIndicator(color: Colors.white),
                    ),
                  if (ready && (_controlsVisible || _isAudio))
                    Align(
                      alignment: Alignment.bottomCenter,
                      child: _Controls(
                        player: player,
                        clock: _clock,
                        onSeekBy: _seekBy,
                      ),
                    ),
                ],
              ),
            ),
    );
  }
}

class _Controls extends StatelessWidget {
  const _Controls({
    required this.player,
    required this.clock,
    required this.onSeekBy,
  });

  final VideoPlayerController player;
  final String Function(Duration) clock;
  final void Function(Duration) onSeekBy;

  @override
  Widget build(BuildContext context) {
    final value = player.value;
    final total = value.duration.inMilliseconds;
    final position = value.position.inMilliseconds.clamp(0, total);
    final finished = total > 0 && position >= total;
    return Container(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.bottomCenter,
          end: Alignment.topCenter,
          colors: [Colors.black87, Colors.transparent],
        ),
      ),
      padding: const EdgeInsets.fromLTRB(12, 32, 12, 12),
      child: SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                Text(
                  clock(value.position),
                  style: const TextStyle(color: Colors.white, fontSize: 12),
                ),
                Expanded(
                  child: Slider(
                    value: total == 0 ? 0 : position / total,
                    onChanged: total == 0
                        ? null
                        : (v) => player.seekTo(
                            Duration(milliseconds: (v * total).round()),
                          ),
                  ),
                ),
                Text(
                  clock(value.duration),
                  style: const TextStyle(color: Colors.white, fontSize: 12),
                ),
              ],
            ),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                IconButton(
                  tooltip: 'Back 10 seconds',
                  iconSize: 32,
                  color: Colors.white,
                  icon: const Icon(Icons.replay_10),
                  onPressed: () => onSeekBy(const Duration(seconds: -10)),
                ),
                const SizedBox(width: 16),
                IconButton.filled(
                  tooltip: value.isPlaying ? 'Pause' : 'Play',
                  iconSize: 40,
                  icon: Icon(
                    finished
                        ? Icons.replay
                        : value.isPlaying
                        ? Icons.pause
                        : Icons.play_arrow,
                  ),
                  onPressed: () async {
                    if (finished) await player.seekTo(Duration.zero);
                    value.isPlaying && !finished
                        ? await player.pause()
                        : await player.play();
                  },
                ),
                const SizedBox(width: 16),
                IconButton(
                  tooltip: 'Forward 10 seconds',
                  iconSize: 32,
                  color: Colors.white,
                  icon: const Icon(Icons.forward_10),
                  onPressed: () => onSeekBy(const Duration(seconds: 10)),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _PlaybackError extends StatelessWidget {
  const _PlaybackError({required this.message, required this.onOpenElsewhere});
  final String message;
  final VoidCallback onOpenElsewhere;

  @override
  Widget build(BuildContext context) => Center(
    child: Padding(
      padding: const EdgeInsets.all(32),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.error_outline, color: Colors.white54, size: 56),
          const SizedBox(height: 12),
          const Text(
            'This file cannot be played here.',
            style: TextStyle(color: Colors.white, fontSize: 16),
          ),
          const SizedBox(height: 4),
          Text(
            message,
            maxLines: 3,
            overflow: TextOverflow.ellipsis,
            textAlign: TextAlign.center,
            style: const TextStyle(color: Colors.white54, fontSize: 12),
          ),
          const SizedBox(height: 16),
          FilledButton.tonal(
            onPressed: onOpenElsewhere,
            child: const Text('Download and open in another app'),
          ),
        ],
      ),
    ),
  );
}
