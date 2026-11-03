import 'package:flutter/material.dart';
import 'package:package_info_plus/package_info_plus.dart';

import '../app/prefs.dart';
import '../update/updater.dart';
import 'library_screen.dart' show showReaderTip;

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
