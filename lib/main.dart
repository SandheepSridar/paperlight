import 'package:flutter/material.dart';
import 'package:pdfrx/pdfrx.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'app/prefs.dart';
import 'app/theme.dart';
import 'data/db.dart';
import 'data/library_repo.dart';
import 'ui/library_screen.dart';
import 'update/updater.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  pdfrxFlutterInitialize(); // needed: the importer renders PDF covers directly
  final db = await openAppDatabase();
  final prefs = ReaderPrefs(await SharedPreferences.getInstance());
  runApp(PaperlightApp(repo: LibraryRepo(db), prefs: prefs));
}

class PaperlightApp extends StatefulWidget {
  const PaperlightApp({super.key, required this.repo, required this.prefs});
  final LibraryRepo repo;
  final ReaderPrefs prefs;

  @override
  State<PaperlightApp> createState() => _PaperlightAppState();
}

class _PaperlightAppState extends State<PaperlightApp> {
  late final Updater _updater = Updater(widget.prefs);
  late bool _dark = widget.prefs.theme == PageTheme.dark;

  @override
  void initState() {
    super.initState();
    widget.prefs.addListener(_onPrefs);
  }

  @override
  void dispose() {
    widget.prefs.removeListener(_onPrefs);
    super.dispose();
  }

  // Only rebuild the app shell when light/dark actually flips, not on every
  // slider movement in the reading settings.
  void _onPrefs() {
    final dark = widget.prefs.theme == PageTheme.dark;
    if (dark != _dark) setState(() => _dark = dark);
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Paperlight',
      debugShowCheckedModeBanner: false,
      theme: buildAppTheme(Brightness.light),
      darkTheme: buildAppTheme(Brightness.dark),
      // Night page colour makes the whole app dark, so menus don't glare.
      themeMode: _dark ? ThemeMode.dark : ThemeMode.light,
      home: LibraryScreen(
          repo: widget.repo, prefs: widget.prefs, updater: _updater),
    );
  }
}
