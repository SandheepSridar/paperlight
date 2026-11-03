import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_epub_viewer/flutter_epub_viewer.dart';

import '../../app/prefs.dart';
import '../../app/theme.dart';
import '../../data/library_repo.dart';
import '../../data/models.dart';
import 'reader_chrome.dart';
import 'reader_session.dart';
import 'reader_sheets.dart';

class EpubReaderScreen extends StatefulWidget {
  const EpubReaderScreen(
      {super.key, required this.book, required this.repo, required this.prefs});
  final Book book;
  final LibraryRepo repo;
  final ReaderPrefs prefs;

  @override
  State<EpubReaderScreen> createState() => _EpubReaderScreenState();
}

class _EpubReaderScreenState extends State<EpubReaderScreen> {
  late final ReaderSession _session = ReaderSession(widget.prefs);
  final _controller = EpubController();
  final _save = Debouncer(const Duration(milliseconds: 700));
  late final AppLifecycleListener _life;
  late final EpubSource _source = EpubSource.fromFile(File(widget.book.path));

  bool _ready = false; // cached locations loaded from DB
  String? _initialLocations;
  bool _loaded = false; // first page displayed
  bool _locationsReady = false;

  /// False until the saved position has been restored. Until then any
  /// relocation (e.g. the viewer briefly showing page 1) is NOT saved, so a
  /// glitch during opening can never overwrite the reader's place.
  bool _settled = false;
  String? _error;

  bool _chrome = false;
  late double _progress = widget.book.progress;
  String? _cfi;
  int? _chapterPage, _chapterPages;
  List<EpubChapter> _chapters = const [];
  Set<String> _marked = {};

  // Applied-to-webview values, so we only push what changed.
  late int _fontSize = widget.prefs.fontSize;
  late String _themeKey = _themeSignature();

  // Tap detection: epub.js reports raw touches; a short, still touch is a tap.
  Offset? _down;
  DateTime? _downAt;

  @override
  void initState() {
    super.initState();
    _session.begin();
    widget.prefs.addListener(_onPrefs);
    _life = AppLifecycleListener(onPause: _save.flush, onHide: _save.flush);
    widget.repo.markOpened(widget.book.id);
    _loadMarks();
    widget.repo.epubLocations(widget.book.id).then((l) {
      if (mounted) setState(() => (_initialLocations = l, _ready = true));
    });
  }

  @override
  void dispose() {
    _save.flush();
    _life.dispose();
    widget.prefs.removeListener(_onPrefs);
    _session.end();
    super.dispose();
  }

  String _themeSignature() {
    final p = widget.prefs;
    return '${p.theme.index}-${p.font.index}-${p.lineStep}';
  }

  EpubTheme _epubTheme() {
    final p = widget.prefs;
    String hex(Color c) =>
        '#${(c.toARGB32() & 0xFFFFFF).toRadixString(16).padLeft(6, '0')}';
    final fg = '${hex(p.theme.foreground)} !important';
    final bg = '${hex(p.theme.background)} !important';
    final lh = '${p.lineHeight} !important';
    final family = '${p.font.css} !important';
    // Note: the viewer merges these rules with Object.assign, so our 'body'
    // rule replaces its own — colours must be set here, not via
    // foregroundColor, or Night mode shows dark text on black.
    return EpubTheme.custom(
      backgroundDecoration: BoxDecoration(color: p.theme.background),
      foregroundColor: p.theme.foreground,
      customCss: {
        'body': {
          'color': fg,
          'background': bg,
          'font-family': family,
          'line-height': lh,
        },
        'p, li, div, span, blockquote, td, th, dd, dt': {
          'color': fg,
          'font-family': family,
          'line-height': lh,
          if (p.font == ReadingFont.easy) 'letter-spacing': '0.03em',
          if (p.font == ReadingFont.easy) 'word-spacing': '0.12em',
        },
        'h1, h2, h3, h4, h5, h6': {'color': fg, 'font-family': family},
        'a': {'color': 'inherit !important'},
        'img': {'max-width': '100% !important', 'height': 'auto !important'},
      },
    );
  }

  /// Pushes current typography to the web view. Layout changes reflow the
  /// book, so we then return to the page the reader was on.
  Future<void> _applyTypography({bool force = false}) async {
    final p = widget.prefs;
    var changed = false;
    if (force || p.fontSize != _fontSize) {
      _fontSize = p.fontSize;
      await _controller.setFontSize(fontSize: _fontSize.toDouble());
      changed = true;
    }
    final sig = _themeSignature();
    if (force || sig != _themeKey) {
      _themeKey = sig;
      await _controller.updateTheme(theme: _epubTheme());
      changed = true;
    }
    final cfi = _cfi ?? widget.book.location;
    if (changed && cfi != null && !force) {
      await Future<void>.delayed(const Duration(milliseconds: 250));
      if (mounted) _controller.display(cfi: cfi);
    }
  }

  /// The viewer reports "displayed" as soon as the first section draws.
  /// The initial theme isn't reliably applied by then, so push it, let the
  /// book reflow, and only then go to the saved position.
  Future<void> _onFirstDisplay() async {
    if (_loaded) return;
    setState(() => _loaded = true);
    await _applyTypography(force: true);
    final saved = widget.book.location;
    if (saved != null && saved.isNotEmpty) {
      await Future<void>.delayed(const Duration(milliseconds: 300));
      if (!mounted) return;
      _controller.display(cfi: saved);
      await Future<void>.delayed(const Duration(milliseconds: 700));
    }
    _settled = true;
  }

  void _onPrefs() {
    _session.apply();
    if (_loaded) _applyTypography();
    setState(() {}); // margins / chrome colours
  }

  Future<void> _loadMarks() async {
    final b = await widget.repo.bookmarks(widget.book.id);
    if (mounted) setState(() => _marked = b.map((e) => e.location).toSet());
  }

  void _onRelocated(EpubLocation loc) {
    setState(() {
      _cfi = loc.startCfi;
      _chapterPage = loc.chapterPage;
      _chapterPages = loc.chapterTotalPages;
      // Until epub.js has computed locations, progress reads as 0: keep the
      // last known value rather than resetting the library's progress bar.
      if (_locationsReady || loc.progress > 0) _progress = loc.progress;
    });
    if (!_settled) return;
    final cfi = loc.startCfi;
    final progress = _progress;
    _save.run(() => widget.repo
        .saveProgress(widget.book.id, location: cfi, progress: progress));
  }

  void _touchDown(double x, double y) {
    _down = Offset(x, y);
    _downAt = DateTime.now();
  }

  void _touchUp(double x, double y) {
    final d = _down, at = _downAt;
    _down = null;
    if (d == null || at == null) return;
    final still = (Offset(x, y) - d).distance < 0.03;
    final quick = DateTime.now().difference(at) < const Duration(milliseconds: 350);
    if (!still || !quick) return; // swipe (handled by epub.js) or long-press select
    if (_chrome) {
      setState(() => _chrome = false);
    } else if (x < 0.3) {
      _settled = true;
      _controller.prev();
    } else if (x > 0.7) {
      _settled = true;
      _controller.next();
    } else {
      setState(() => _chrome = true);
    }
  }

  Future<void> _toggleBookmark() async {
    final cfi = _cfi;
    if (cfi == null) return;
    if (_marked.contains(cfi)) {
      final all = await widget.repo.bookmarks(widget.book.id);
      for (final b in all.where((b) => b.location == cfi)) {
        await widget.repo.deleteBookmark(b.id!);
      }
    } else {
      var label = '${(_progress * 100).round()}% through';
      try {
        final t = (await _controller.extractCurrentPageText()).text?.trim();
        if (t != null && t.isNotEmpty) {
          final oneLine = t.replaceAll(RegExp(r'\s+'), ' ');
          label = oneLine.length > 70 ? '${oneLine.substring(0, 70)}…' : oneLine;
        }
      } catch (_) {}
      await widget.repo.addBookmark(Bookmark(
          bookId: widget.book.id,
          location: cfi,
          label: label,
          progress: _progress,
          createdAt: DateTime.now()));
    }
    await _loadMarks();
  }

  void _contents() {
    final entries = <TocEntry>[];
    void walk(List<EpubChapter> list, int depth) {
      for (final c in list) {
        entries.add(TocEntry(c.title.trim(), depth,
            () {
              _settled = true;
              _controller.display(cfi: c.href);
            }));
        walk(c.subitems, depth + 1);
      }
    }

    walk(_chapters, 0);
    showContentsSheet(context, entries);
  }

  String get _label {
    final pct = '${(_progress * 100).round()}%';
    final cp = _chapterPage, ct = _chapterPages;
    if (cp != null && ct != null && ct > 0) {
      final left = ct - cp;
      return left <= 0
          ? 'Last page in chapter · $pct'
          : '$left page${left == 1 ? '' : 's'} left in chapter · $pct';
    }
    return pct;
  }

  @override
  Widget build(BuildContext context) {
    final p = widget.prefs;
    final theme = p.theme;
    return Scaffold(
      backgroundColor: theme.background,
      body: ReaderChrome(
        visible: _chrome,
        theme: theme,
        title: widget.book.title,
        progress: _progress,
        progressLabel: _label,
        bookmarked: _cfi != null && _marked.contains(_cfi),
        seekLabel: (v) => '${(v * 100).round()}%',
        onSeek: (v) {
          if (!_loaded) return;
          _settled = true;
          _controller.toProgressPercentage(v);
        },
        onBack: () => Navigator.pop(context),
        onContents: _contents,
        onBookmarks: () => showBookmarksSheet(context,
            load: () => widget.repo.bookmarks(widget.book.id),
            onOpen: (b) {
              _settled = true;
              _controller.display(cfi: b.location);
            },
            onDelete: (b) async {
              await widget.repo.deleteBookmark(b.id!);
              await _loadMarks();
            }),
        onToggleBookmark: _toggleBookmark,
        onSettings: () => showDisplaySheet(context, prefs: p, isEpub: true),
        child: _error != null
            ? Center(
                child: Padding(
                  padding: const EdgeInsets.all(32),
                  child: Text(
                    "Sorry, this book couldn't be opened.\n$_error",
                    textAlign: TextAlign.center,
                    style: TextStyle(color: theme.foreground, fontSize: 18),
                  ),
                ),
              )
            : !_ready
                ? const Center(child: CircularProgressIndicator())
                : Stack(children: [
                    SafeArea(
                      child: AnimatedPadding(
                        duration: const Duration(milliseconds: 150),
                        padding: EdgeInsets.fromLTRB(p.margin, 20, p.margin, 28),
                        child: EpubViewer(
                          epubController: _controller,
                          epubSource: _source,
                          initialCfi: widget.book.location,
                          initialLocations: _initialLocations,
                          displaySettings: EpubDisplaySettings(
                            flow: EpubFlow.paginated,
                            snap: true,
                            spread: EpubSpread.none,
                            fontSize: _fontSize,
                            theme: _epubTheme(),
                          ),
                          onEpubLoaded: _onFirstDisplay,
                          onLoadError: (e) => setState(() => _error = e.message),
                          onChaptersLoaded: (c) => _chapters = c,
                          onRelocated: _onRelocated,
                          onLocationLoaded: () => _locationsReady = true,
                          onLocationsGenerated: (l) =>
                              widget.repo.saveEpubLocations(widget.book.id, l),
                          onTouchDown: _touchDown,
                          onTouchUp: _touchUp,
                        ),
                      ),
                    ),
                    if (!_loaded)
                      Positioned.fill(
                        child: ColoredBox(
                          color: theme.background,
                          child: const Center(child: CircularProgressIndicator()),
                        ),
                      ),
                  ]),
      ),
    );
  }
}
