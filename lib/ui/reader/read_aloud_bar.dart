import 'package:flutter/material.dart';

import '../../app/prefs.dart';
import '../../tts/read_aloud_controller.dart';
import '../../tts/voice_engine.dart';
import 'reader_session.dart';

/// Read-aloud plumbing shared by the PDF and EPUB readers.
mixin ReadAloudHost<T extends StatefulWidget> on State<T> {
  ReadAloudController? readAloud;

  ReaderPrefs get hostPrefs;
  ReaderSession get hostSession;
  NarrationSource createNarrationSource();

  bool get readingAloud => readAloud?.active ?? false;

  /// Asks to download the voice the first time, then reads from this page
  /// (from character [fromOffset] of its text, when given).
  Future<void> startReadAloud({int? fromOffset}) async {
    if (!await ensureVoiceInstalled(context) || !mounted) return;
    final c = readAloud ??= ReadAloudController(
      source: createNarrationSource(),
      voiceId: hostPrefs.ttsVoice,
      speed: hostPrefs.ttsSpeed,
    )
      ..onNotice = _notice
      ..addListener(_onReadAloudChanged);
    await c.start(fromOffset: fromOffset);
  }

  void _notice(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  /// Keeps the screen awake while the voice is reading.
  void _onReadAloudChanged() {
    final active = readAloud?.active ?? false;
    if (hostSession.keepAwake == active) return;
    hostSession.keepAwake = active;
    hostSession.apply();
  }

  /// The reader moved to another page by hand: carry on reading from there.
  void readAloudFollow() => readAloud?.restartIfActive();

  void pauseReadAloud() => readAloud?.pause();

  void disposeReadAloud() {
    final c = readAloud;
    readAloud = null;
    if (c == null) return;
    c.removeListener(_onReadAloudChanged);
    c.stop().whenComplete(c.dispose);
    // Free the voice model's memory once the book is closed.
    VoiceEngine.instance.shutdown();
  }

  /// The floating player, raised above the bottom menu when it is open.
  Widget readAloudBar({required bool chromeVisible, bool hidden = false}) {
    // Must be a direct child of the reader's Stack, hence Positioned first.
    final c = readAloud;
    return AnimatedPositioned(
      duration: const Duration(milliseconds: 180),
      curve: Curves.easeOut,
      left: 12,
      right: 12,
      bottom: (chromeVisible ? 130 : 24) + MediaQuery.paddingOf(context).bottom,
      child: c == null || hidden
          ? const SizedBox.shrink()
          : ListenableBuilder(
              listenable: c,
              builder: (context, _) => c.active
                  ? Center(child: ReadAloudBar(controller: c, prefs: hostPrefs))
                  : const SizedBox.shrink(),
            ),
    );
  }
}

/// Floating player shown while the book is being read aloud.
class ReadAloudBar extends StatelessWidget {
  const ReadAloudBar({super.key, required this.controller, required this.prefs});
  final ReadAloudController controller;
  final ReaderPrefs prefs;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        final c = controller;
        final starting = c.state == ReadAloudState.starting;
        final playing = c.state == ReadAloudState.playing;
        return Material(
          elevation: 10,
          color: scheme.surfaceContainerHigh,
          borderRadius: BorderRadius.circular(28),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              const SizedBox(width: 6),
              Icon(Icons.headphones_rounded, color: scheme.primary),
              const SizedBox(width: 8),
              SizedBox(
                width: 56,
                height: 56,
                child: starting
                    ? const Padding(
                        padding: EdgeInsets.all(16),
                        child: CircularProgressIndicator(strokeWidth: 3),
                      )
                    : IconButton.filled(
                        iconSize: 30,
                        tooltip: playing ? 'Pause' : 'Play',
                        icon: Icon(playing ? Icons.pause_rounded : Icons.play_arrow_rounded),
                        onPressed: playing ? c.pause : c.resume,
                      ),
              ),
              const SizedBox(width: 4),
              TextButton(
                onPressed: () => _pickSpeed(context),
                child: Text('${_fmt(c.speed)}×', style: const TextStyle(fontSize: 17)),
              ),
              TextButton.icon(
                onPressed: () => showVoiceSheet(context, prefs: prefs, controller: c),
                icon: const Icon(Icons.record_voice_over_outlined),
                label: Text(voiceById(c.voiceId).name, style: const TextStyle(fontSize: 17)),
              ),
              IconButton(
                tooltip: 'Stop reading',
                icon: const Icon(Icons.close_rounded),
                onPressed: c.stop,
              ),
            ]),
          ),
        );
      },
    );
  }

  static String _fmt(double v) => v.toStringAsFixed(1).replaceAll('.0', '');

  Future<void> _pickSpeed(BuildContext context) async {
    final v = await showModalBottomSheet<double>(
      context: context,
      showDragHandle: true,
      builder: (c) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          const Text('Reading speed',
              style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700)),
          const SizedBox(height: 8),
          for (final s in ReaderPrefs.ttsSpeeds)
            ListTile(
              title: Text('${_fmt(s)}×${s == 1.0 ? '  (normal)' : ''}',
                  style: const TextStyle(fontSize: 18)),
              trailing: s == controller.speed ? const Icon(Icons.check_rounded) : null,
              onTap: () => Navigator.pop(c, s),
            ),
        ]),
      ),
    );
    if (v == null || v == controller.speed) return;
    prefs.ttsSpeed = v;
    controller.updateVoice(newSpeed: v);
  }
}

Future<void> showVoiceSheet(BuildContext context,
    {required ReaderPrefs prefs, ReadAloudController? controller}) async {
  // Grouped by accent: American, British, Indian.
  final groups = <String, List<Voice>>{};
  for (final v in voices) {
    groups.putIfAbsent(v.description.split(', ').last, () => []).add(v);
  }
  final v = await showModalBottomSheet<Voice>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (c) => DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.75,
      maxChildSize: 0.95,
      builder: (c, scroll) => ListView(controller: scroll, children: [
        const Padding(
          padding: EdgeInsets.fromLTRB(24, 0, 24, 4),
          child: Text('Voice', style: TextStyle(fontSize: 22, fontWeight: FontWeight.w700)),
        ),
        for (final g in groups.entries) ...[
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 14, 24, 2),
            child: Text(g.key,
                style: TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                    color: Theme.of(c).colorScheme.primary)),
          ),
          for (final voice in g.value)
            ListTile(
              contentPadding: const EdgeInsets.symmetric(horizontal: 24),
              leading: const Icon(Icons.record_voice_over_outlined),
              title: Text(voice.name, style: const TextStyle(fontSize: 18)),
              subtitle: Text(voice.description.split(', ').first),
              trailing: voice.id == prefs.ttsVoice ? const Icon(Icons.check_rounded) : null,
              onTap: () => Navigator.pop(c, voice),
            ),
        ],
        const SizedBox(height: 16),
      ]),
    ),
  );
  if (v == null || v.id == prefs.ttsVoice) return;
  prefs.ttsVoice = v.id;
  controller?.updateVoice(voice: v.id);
}

/// Makes sure the voice is on the tablet, asking before the one-time
/// download. Returns true when it is ready to use.
Future<bool> ensureVoiceInstalled(BuildContext context) async {
  if (await VoiceModel.instance.isInstalled()) return true;
  final upgrade = await VoiceModel.instance.hasOlderVoice();
  if (!context.mounted) return false;
  final ok = await showDialog<bool>(
    context: context,
    builder: (c) => AlertDialog(
      icon: const Icon(Icons.headphones_rounded),
      title: Text(upgrade ? 'Get the new voices?' : 'Download the reading voice?'),
      content: Text(upgrade
          ? 'Read aloud now has more natural voices, including Indian, British '
              'and American narrators.\n\n'
              'They replace the old voice: a one-time download of about '
              '${VoiceModel.downloadMb} MB. Wi-Fi is best.'
          : 'Paperlight reads aloud with natural voices that run on this device, '
              'so it works offline and your books stay private.\n\n'
              'The voices are a one-time download of about ${VoiceModel.downloadMb} MB. '
              'Wi-Fi is best.'),
      actions: [
        TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Not now')),
        FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('Download')),
      ],
    ),
  );
  if (ok != true || !context.mounted) return false;
  final done = await showDialog<bool>(
    context: context,
    barrierDismissible: false,
    builder: (c) => const _VoiceDownloadDialog(),
  );
  return done == true;
}

class _VoiceDownloadDialog extends StatefulWidget {
  const _VoiceDownloadDialog();

  @override
  State<_VoiceDownloadDialog> createState() => _VoiceDownloadDialogState();
}

class _VoiceDownloadDialogState extends State<_VoiceDownloadDialog> {
  double? _progress = 0;
  bool _unpacking = false;
  String? _error;
  bool _cancelled = false;

  @override
  void initState() {
    super.initState();
    _start();
  }

  Future<void> _start() async {
    setState(() {
      _error = null;
      _progress = 0;
      _unpacking = false;
      _cancelled = false;
    });
    try {
      await VoiceModel.instance.install(
        cancelled: () => _cancelled,
        onProgress: (v) {
          if (!mounted) return;
          setState(() {
            _progress = v;
            _unpacking = v == null;
          });
        },
      );
      if (mounted) Navigator.pop(context, true);
    } catch (e) {
      if (!mounted || isCancelled(e)) return;
      setState(() => _error =
          "The voice couldn't be downloaded. Check the internet connection and try again.");
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(_error != null ? 'Download problem' : 'Downloading the voice…'),
      content: _error != null
          ? Text(_error!)
          : Column(mainAxisSize: MainAxisSize.min, children: [
              LinearProgressIndicator(value: _progress, minHeight: 8),
              const SizedBox(height: 12),
              Text(_unpacking
                  ? 'Getting it ready…'
                  : '${((_progress ?? 0) * 100).round()}% of ${VoiceModel.downloadMb} MB'),
            ]),
      actions: [
        if (_error != null) ...[
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Close')),
          FilledButton(onPressed: _start, child: const Text('Try again')),
        ] else if (!_unpacking)
          TextButton(
              onPressed: () {
                _cancelled = true;
                Navigator.pop(context, false);
              },
              child: const Text('Cancel')),
      ],
    );
  }
}
