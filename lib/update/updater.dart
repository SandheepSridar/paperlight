import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:ota_update/ota_update.dart';
import 'package:package_info_plus/package_info_plus.dart';

import '../app/prefs.dart';
import 'version.dart';

/// GitHub repo that publishes releases. Override at build time with
/// `--dart-define=UPDATE_REPO=owner/name`.
const updateRepo = String.fromEnvironment('UPDATE_REPO',
    defaultValue: 'SandheepSridar/paperlight');

class UpdateInfo {
  UpdateInfo(this.version, this.apkUrl, this.notes);
  final String version;
  final String apkUrl;
  final String notes;
}

class Updater {
  Updater(this.prefs);
  final ReaderPrefs prefs;

  /// One small HTTPS request, at most once a day unless [force]d.
  Future<UpdateInfo?> check({bool force = false}) async {
    final last = prefs.lastUpdateCheck;
    if (!force &&
        last != null &&
        DateTime.now().difference(last) < const Duration(hours: 24)) {
      return null;
    }
    final res = await http.get(
      Uri.parse('https://api.github.com/repos/$updateRepo/releases/latest'),
      headers: {'Accept': 'application/vnd.github+json'},
    ).timeout(const Duration(seconds: 10));
    prefs.lastUpdateCheck = DateTime.now();
    if (res.statusCode != 200) return null;

    final json = jsonDecode(res.body) as Map<String, dynamic>;
    final tag = json['tag_name'] as String? ?? '';
    final current = (await PackageInfo.fromPlatform()).version;
    if (compareVersions(tag, current) <= 0) return null;

    final assets = (json['assets'] as List).cast<Map<String, dynamic>>();
    final apks = assets
        .where((a) => (a['name'] as String).endsWith('.apk'))
        .toList();
    if (apks.isEmpty) return null;
    // Galaxy Tabs are arm64; prefer that split APK, else any APK.
    final apk = apks.firstWhere(
        (a) => (a['name'] as String).contains('arm64'),
        orElse: () => apks.first);
    return UpdateInfo(tag.replaceFirst(RegExp('^v'), ''),
        apk['browser_download_url'] as String, json['body'] as String? ?? '');
  }

  /// Silent background check at startup; shows a dialog only if newer.
  Future<void> checkOnStartup(BuildContext context) async {
    try {
      final info = await check();
      if (info != null && context.mounted) await showUpdateDialog(context, info);
    } catch (_) {
      // Offline or GitHub unreachable: try again tomorrow, never bother the user.
    }
  }

  /// Manual "Check for updates" from Settings.
  Future<void> checkManually(BuildContext context) async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      final info = await check(force: true);
      if (!context.mounted) return;
      if (info == null) {
        messenger.showSnackBar(
            const SnackBar(content: Text("You're on the latest version.")));
      } else {
        await showUpdateDialog(context, info);
      }
    } catch (_) {
      messenger.showSnackBar(const SnackBar(
          content: Text("Couldn't check for updates. Are you online?")));
    }
  }
}

Future<void> showUpdateDialog(BuildContext context, UpdateInfo info) async {
  final go = await showDialog<bool>(
    context: context,
    builder: (c) => AlertDialog(
      icon: const Icon(Icons.system_update_rounded, size: 40),
      title: const Text('A new version is ready'),
      content: SingleChildScrollView(
        child: Text(
          'Version ${info.version} is available.'
          '${info.notes.trim().isEmpty ? '' : '\n\n${info.notes.trim()}'}'
          '\n\nYour books and reading progress are kept.',
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Later')),
        FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('Update now')),
      ],
    ),
  );
  if (go == true && context.mounted) {
    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => _DownloadDialog(info: info),
    );
  }
}

class _DownloadDialog extends StatefulWidget {
  const _DownloadDialog({required this.info});
  final UpdateInfo info;

  @override
  State<_DownloadDialog> createState() => _DownloadDialogState();
}

class _DownloadDialogState extends State<_DownloadDialog> {
  StreamSubscription<OtaEvent>? _sub;
  double? _progress;
  String? _error;

  @override
  void initState() {
    super.initState();
    _start();
  }

  void _start() {
    setState(() {
      _error = null;
      _progress = null;
    });
    try {
      _sub = OtaUpdate()
          .execute(widget.info.apkUrl,
              destinationFilename: 'paperlight-${widget.info.version}.apk')
          .listen((e) {
        if (!mounted) return;
        switch (e.status) {
          case OtaStatus.DOWNLOADING:
            setState(() => _progress = (double.tryParse(e.value ?? '') ?? 0) / 100);
          case OtaStatus.INSTALLING:
            // Android's installer takes over; close our dialog.
            Navigator.of(context).pop();
          case OtaStatus.PERMISSION_NOT_GRANTED_ERROR:
            setState(() => _error =
                'Please allow Paperlight to install updates, then try again.\n\n'
                'Settings › Apps › Special access › Install unknown apps › Paperlight');
          default:
            if (e.status.name.contains('ERROR')) {
              setState(() => _error = 'The download failed. Please try again.');
            }
        }
      }, onError: (_) {
        if (mounted) setState(() => _error = 'The download failed. Please try again.');
      });
    } catch (_) {
      setState(() => _error = 'The download failed. Please try again.');
    }
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(_error == null ? 'Downloading update…' : 'Update problem'),
      content: _error != null
          ? Text(_error!)
          : Column(mainAxisSize: MainAxisSize.min, children: [
              LinearProgressIndicator(value: _progress, minHeight: 8),
              const SizedBox(height: 12),
              Text(_progress == null ? 'Starting…' : '${(_progress! * 100).round()}%'),
              const SizedBox(height: 8),
              const Text('When it finishes, tap "Install" (or "Update").'),
            ]),
      actions: [
        if (_error != null) ...[
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Close')),
          FilledButton(onPressed: _start, child: const Text('Try again')),
        ] else
          TextButton(
              onPressed: () {
                _sub?.cancel();
                Navigator.pop(context);
              },
              child: const Text('Cancel')),
      ],
    );
  }
}
