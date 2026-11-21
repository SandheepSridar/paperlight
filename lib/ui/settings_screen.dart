import 'package:flutter/material.dart';
import 'package:package_info_plus/package_info_plus.dart';

import '../app/prefs.dart';
import '../tts/voice_engine.dart';
import '../update/updater.dart';
import 'library_screen.dart' show showReaderTip;
import 'reader/read_aloud_bar.dart' show showVoiceSheet, ensureVoiceInstalled;

class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key, required this.prefs, required this.updater});
  final ReaderPrefs prefs;
  final Updater updater;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: ListenableBuilder(
        listenable: prefs,
        builder: (context, _) => ListView(children: [
          SwitchListTile(
            secondary: const Icon(Icons.screen_lock_portrait_outlined),
            title: const Text('Keep screen on while reading'),
            subtitle: const Text('Off saves battery: the screen turns off as usual.'),
            value: prefs.keepScreenOn,
            onChanged: (v) => prefs.keepScreenOn = v,
          ),
          _VoiceTile(prefs: prefs),
          ListTile(
            leading: const Icon(Icons.help_outline_rounded),
            title: const Text('How to read'),
            onTap: () => showReaderTip(context),
          ),
          const Divider(),
          ListTile(
            leading: const Icon(Icons.system_update_rounded),
            title: const Text('Check for updates'),
            onTap: () => updater.checkManually(context),
          ),
          FutureBuilder(
            future: PackageInfo.fromPlatform(),
            builder: (c, s) => ListTile(
              leading: const Icon(Icons.info_outline_rounded),
              title: const Text('Paperlight'),
              subtitle: Text(s.hasData ? 'Version ${s.data!.version}' : ''),
            ),
          ),
        ]),
      ),
    );
  }
}

/// Read-aloud voice: pick a narrator, download the voice, or remove it.
class _VoiceTile extends StatefulWidget {
  const _VoiceTile({required this.prefs});
  final ReaderPrefs prefs;

  @override
  State<_VoiceTile> createState() => _VoiceTileState();
}

class _VoiceTileState extends State<_VoiceTile> {
  late Future<bool> _installed = VoiceModel.instance.isInstalled();

  void _refresh() => setState(() => _installed = VoiceModel.instance.isInstalled());

  Future<void> _remove() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Remove the reading voice?'),
        content: const Text('This frees about ${VoiceModel.installedMb} MB. '
            'You can download it again the next time you use Read aloud.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Keep')),
          FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('Remove')),
        ],
      ),
    );
    if (ok != true) return;
    await VoiceModel.instance.remove();
    _refresh();
  }

  @override
  Widget build(BuildContext context) => FutureBuilder<bool>(
        future: _installed,
        builder: (context, snap) {
          final installed = snap.data ?? false;
          final voice = voiceById(widget.prefs.ttsVoice);
          return ListTile(
            leading: const Icon(Icons.headphones_rounded),
            title: const Text('Read-aloud voice'),
            subtitle: Text(installed
                ? '${voice.name} (${voice.description.toLowerCase()}) · on this tablet'
                : 'Not downloaded yet (about ${VoiceModel.downloadMb} MB)'),
            onTap: () async {
              if (installed) {
                await showVoiceSheet(context, prefs: widget.prefs);
              } else {
                await ensureVoiceInstalled(context);
                _refresh();
              }
            },
            trailing: installed
                ? IconButton(
                    tooltip: 'Remove voice',
                    icon: const Icon(Icons.delete_outline_rounded),
                    onPressed: _remove,
                  )
                : null,
          );
        },
      );
}
