import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_epub_viewer/flutter_epub_viewer.dart';

import '../../app/prefs.dart';
import '../../app/theme.dart';
import '../../data/library_repo.dart';
import '../../data/models.dart';
import 'annotation_menus.dart';
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
  Offset? _lastTouch;
  DateTime? _downAt;

  // Highlights / underlines / notes.
  List<Annotation> _annotations = [];
  _Menu? _menu;
  bool _marksApplied = false;
  Timer? _pendingTap;
  DateTime? _markTapAt;
  final _stackKey = GlobalKey();
  final _viewerKey = GlobalKey();

  @override
  void initState() {
    super.initState();
    _session.begin();
    widget.prefs.addListener(_onPrefs);
    _life = AppLifecycleListener(onPause: _save.flush, onHide: _save.flush);
    widget.repo.markOpened(widget.book.id);
    _loadMarks();
    widget.repo.annotations(widget.book.id).then((a) {
      if (!mounted) return;
      _annotations = a;
      if (_settled) _applyMarks();
    });
    widget.repo.epubLocations(widget.book.id).then((l) {
      if (mounted) setState(() => (_initialLocations = l, _ready = true));
    });
  }

  @override
  void dispose() {
    _save.flush();
    _pendingTap?.cancel();
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
    _applyMarks();
  }

  // ---------------------------------------------------------------- marks

  /// Draws every saved highlight / underline once the book is on screen.
  /// epub.js keeps them and re-draws them as pages are turned.
  void _applyMarks() {
    if (_marksApplied || !_loaded) return;
    _marksApplied = true;
    for (final a in _annotations) {
      _draw(a);
    }
  }

  void _draw(Annotation a) {
    try {
      if (a.kind == AnnotationKind.underline) {
        _controller.addUnderline(cfi: a.location, color: underlineColor);
      } else if (a.kind == AnnotationKind.highlight) {
        _controller.addHighlight(
            cfi: a.location,
            color: Color(a.color ?? highlightColors.first.toARGB32()),
            opacity: 0.35);
      }
    } catch (_) {}
  }

  void _erase(Annotation a) {
    try {
      if (a.kind == AnnotationKind.underline) {
        _controller.removeUnderline(cfi: a.location);
      } else {
        _controller.removeHighlight(cfi: a.location);
      }
    } catch (_) {}
  }

  /// Converts a rect relative to the web view into Stack coordinates.
  Rect _toStack(Rect r) {
    final viewer = _viewerKey.currentContext?.findRenderObject() as RenderBox?;
    final stack = _stackKey.currentContext?.findRenderObject() as RenderBox?;
    if (viewer == null || stack == null) return r;
    final o = stack.globalToLocal(viewer.localToGlobal(Offset.zero));
    return r.shift(o);
  }

  Size get _viewerSize =>
      (_viewerKey.currentContext?.findRenderObject() as RenderBox?)?.size ??
      Size.zero;

  void _onSelection(String text, String cfi, Rect rect, Rect _) {
    if (text.trim().isEmpty) return;
    setState(() {
      _chrome = false;
      _menu = _Menu(anchor: _toStack(rect), cfi: cfi, text: text);
    });
  }

  void _onAnnotationClicked(String cfi, Map<String, dynamic>? rect) {
    _markTapAt = DateTime.now();
    _pendingTap?.cancel();
    final a = _annotations.where((x) => x.location == cfi).firstOrNull;
    if (a == null) return;
    final size = _viewerSize;
    double v(String k) => (rect?[k] as num?)?.toDouble() ?? 0;
    // The viewer's rect for a tapped mark is often empty (all zeros), so
    // anchor the menu where the finger touched instead.
    final touch = _lastTouch;
    final Rect anchor;
    if (v('right') > v('left') && v('bottom') > v('top')) {
      anchor = _toStack(Rect.fromLTRB(v('left'), v('top'), v('right'), v('bottom')));
    } else if (touch != null) {
      anchor = _toStack(Rect.fromCenter(
          center: Offset(touch.dx * size.width, touch.dy * size.height),
          width: 40,
          height: 40));
    } else {
      anchor = _toStack(Rect.fromCenter(
          center: size.center(Offset.zero), width: 10, height: 10));
    }
    setState(() {
      _chrome = false;
      _menu = _Menu(anchor: anchor, cfi: cfi, text: a.excerpt ?? '', mark: a);
    });
  }

  void _closeMenu({bool clear = true}) {
    if (_menu == null) return;
    final wasSelection = _menu!.mark == null;
    setState(() => _menu = null);
    if (clear && wasSelection) {
      try {
        _controller.clearSelection();
      } catch (_) {}
    }
  }

  Annotation _newMark(_Menu m, AnnotationKind kind, Color color, {String? note}) =>
      Annotation(
        bookId: widget.book.id,
        kind: kind,
        location: m.cfi,
        progress: _progress,
        createdAt: DateTime.now(),
        color: color.toARGB32(),
        excerpt: m.text,
        note: note,
      );

  Future<void> _addMark(Annotation a) async {
    // Re-marking the exact same text replaces the old mark.
    for (final old in _annotations.where((x) => x.location == a.location).toList()) {
      _erase(old);
      await widget.repo.deleteAnnotation(old.id!);
      _annotations.remove(old);
    }
    final saved = await widget.repo.saveAnnotation(a);
    _annotations.add(saved);
    _draw(saved);
  }

  Future<void> _highlight(Color c) async {
    final m = _menu;
    if (m == null) return;
    _closeMenu();
    final mark = m.mark;
    if (mark != null) {
      // Change colour of an existing highlight.
      _erase(mark);
      final updated = await widget.repo.saveAnnotation(mark.copyWith(color: c.toARGB32()));
      _annotations[_annotations.indexOf(mark)] = updated;
      _draw(updated);
    } else {
      await _addMark(_newMark(m, AnnotationKind.highlight, c));
    }
  }

  Future<void> _underline() async {
    final m = _menu;
    if (m == null) return;
    _closeMenu();
    await _addMark(_newMark(m, AnnotationKind.underline, underlineColor));
  }

  Future<void> _note() async {
    final m = _menu;
    if (m == null) return;
    _closeMenu();
    final mark = m.mark;
    final text = await showNoteDialog(context,
        initial: mark?.note, excerpt: m.text, title: mark?.hasNote == true ? 'Edit note' : 'Add a note');
    if (text == null || !mounted) return;
    if (mark != null) {
      final updated = await widget.repo.saveAnnotation(mark.copyWith(note: text));
      _annotations[_annotations.indexOf(mark)] = updated;
    } else if (text.isNotEmpty) {
      // A note always comes with a highlight, so it can be found on the page.
      await _addMark(_newMark(m, AnnotationKind.highlight, highlightColors.first, note: text));
    }
  }

  Future<void> _copy() async {
    final m = _menu;
    if (m == null) return;
    _closeMenu();
    await Clipboard.setData(ClipboardData(text: m.text));
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Copied'), duration: Duration(seconds: 1)));
    }
  }

  Future<void> _remove() async {
    final mark = _menu?.mark;
    if (mark == null) return;
    _closeMenu();
    final what = mark.kind == AnnotationKind.underline ? 'underline' : 'highlight';
    if (!await confirmRemove(context, mark.hasNote ? '$what and its note' : what)) return;
    await _deleteMark(mark);
  }

  Future<void> _deleteMark(Annotation a) async {
    _erase(a);
    await widget.repo.deleteAnnotation(a.id!);
    _annotations.removeWhere((x) => x.id == a.id);
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
      _menu = null; // a turned page leaves the old selection behind
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
    _lastTouch = _down;
    _downAt = DateTime.now();
  }

  void _touchUp(double x, double y) {
    final d = _down, at = _downAt;
    _down = null;
    if (d == null || at == null) return;
    final still = (Offset(x, y) - d).distance < 0.03;
    final quick = DateTime.now().difference(at) < const Duration(milliseconds: 350);
    if (!still || !quick) return; // swipe (handled by epub.js) or long-press select
    final markTap = _markTapAt;
    if (markTap != null &&
        DateTime.now().difference(markTap) < const Duration(milliseconds: 600)) {
      return; // tapped a highlight: its menu is showing
    }
    if (_menu != null) {
      _closeMenu();
      return;
    }
    if (_annotations.isEmpty) {
      _tap(x);
    } else {
      // Give a tap on a highlight a moment to arrive before turning the page.
      _pendingTap?.cancel();
      _pendingTap = Timer(const Duration(milliseconds: 220), () => _tap(x));
    }
  }

  void _tap(double x) {
    if (!mounted) return;
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
      // The keyboard (for notes) must not shrink and reflow the page.
      resizeToAvoidBottomInset: false,
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
        onBookmarks: () => showMarksSheet(context,
            isPdf: false,
            loadBookmarks: () => widget.repo.bookmarks(widget.book.id),
            onOpenBookmark: (b) {
              _settled = true;
              _controller.display(cfi: b.location);
            },
            onDeleteBookmark: (b) async {
              await widget.repo.deleteBookmark(b.id!);
              await _loadMarks();
            },
            loadAnnotations: () async => List.of(_annotations)
              ..sort((a, b) => a.progress.compareTo(b.progress)),
            onOpenAnnotation: (a) {
              _settled = true;
              _controller.display(cfi: a.location);
            },
            onDeleteAnnotation: _deleteMark),
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
                : Stack(key: _stackKey, children: [
                    SafeArea(
                      child: AnimatedPadding(
                        duration: const Duration(milliseconds: 150),
                        padding: EdgeInsets.fromLTRB(p.margin, 20, p.margin, 28),
                        child: EpubViewer(
                          key: _viewerKey,
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
                          suppressNativeContextMenu: true,
                          onSelection: _onSelection,
                          onSelectionChanging: () {
                            if (_menu?.mark == null && _menu != null) {
                              setState(() => _menu = null);
                            }
                          },
                          onDeselection: () {
                            if (_menu?.mark == null && _menu != null) {
                              setState(() => _menu = null);
                            }
                          },
                          onAnnotationClicked: _onAnnotationClicked,
                        ),
                      ),
                    ),
                    if (_menu case final m?)
                      Positioned.fill(
                        child: AnchoredMenu(
                          anchor: m.anchor,
                          child: m.mark == null
                              ? MarkMenu(
                                  onColor: _highlight,
                                  onUnderline: _underline,
                                  onNote: _note,
                                  onCopy: _copy,
                                )
                              : MarkMenu(
                                  onColor: m.mark!.kind == AnnotationKind.highlight
                                      ? _highlight
                                      : null,
                                  selectedColor: m.mark!.color == null
                                      ? null
                                      : Color(m.mark!.color!),
                                  onNote: _note,
                                  noteLabel: m.mark!.hasNote ? 'Edit note' : 'Note',
                                  onCopy: _copy,
                                  onRemove: _remove,
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

/// The pop-up menu's target: a fresh selection, or an existing [mark].
class _Menu {
  _Menu({required this.anchor, required this.cfi, required this.text, this.mark});
  final Rect anchor;
  final String cfi;
  final String text;
  final Annotation? mark;
}
