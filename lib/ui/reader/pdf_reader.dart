import 'package:flutter/material.dart';
import 'package:pdfrx/pdfrx.dart';

import '../../app/prefs.dart';
import '../../app/theme.dart';
import '../../data/library_repo.dart';
import '../../data/models.dart';
import '../../tts/read_aloud_controller.dart';
import 'annotation_menus.dart';
import 'ink/ink_controller.dart';
import 'ink/ink_layer.dart';
import 'ink/ink_toolbar.dart';
import 'read_aloud_bar.dart';
import 'reader_chrome.dart';
import 'reader_session.dart';
import 'reader_sheets.dart';

class PdfReaderScreen extends StatefulWidget {
  const PdfReaderScreen(
      {super.key, required this.book, required this.repo, required this.prefs});
  final Book book;
  final LibraryRepo repo;
  final ReaderPrefs prefs;

  @override
  State<PdfReaderScreen> createState() => _PdfReaderScreenState();
}

class _PdfReaderScreenState extends State<PdfReaderScreen>
    with ReadAloudHost<PdfReaderScreen> {
  late final ReaderSession _session = ReaderSession(widget.prefs);
  final _save = Debouncer(const Duration(milliseconds: 700));
  late final AppLifecycleListener _life;

  PdfDocument? _doc;
  Object? _error;
  late int _page = int.tryParse(widget.book.location ?? '') ?? 1;
  bool _chrome = false;
  Set<String> _marked = {};

  // "Turn pages" mode
  PageController? _pages;
  final _zoom = TransformationController();
  bool _zoomed = false;

  // "Scroll down" mode
  final _viewer = PdfViewerController();

  PdfMode? _mode;

  // Ink and page notes.
  late final InkController _ink =
      InkController(repo: widget.repo, bookId: widget.book.id);
  bool get _penMode => _ink.penMode;

  int get _count => _doc?.pages.length ?? 1;
  double get _progress => _count <= 1 ? 1 : (_page - 1) / (_count - 1);

  @override
  void initState() {
    super.initState();
    _session.begin();
    widget.prefs.addListener(_onPrefs);
    _life = AppLifecycleListener(onPause: _flushAll, onHide: _flushAll);
    widget.repo.markOpened(widget.book.id);
    _loadMarks();
    _ink.load();
    PdfDocument.openFile(widget.book.path).then((d) {
      if (!mounted) return d.dispose();
      _ink.pageCount = d.pages.length;
      setState(() {
        _doc = d;
        _page = _page.clamp(1, d.pages.length);
      });
    }, onError: (e) => mounted ? setState(() => _error = e) : null);
  }

  void _flushAll() {
    // No background playback: reading aloud pauses when the app is left.
    pauseReadAloud();
    _save.flush();
    _ink.flush();
  }

  @override
  void dispose() {
    disposeReadAloud();
    _save.flush();
    final ink = _ink;
    ink.flush().whenComplete(ink.dispose);
    _life.dispose();
    widget.prefs.removeListener(_onPrefs);
    _session.end();
    _pages?.dispose();
    _zoom.dispose();
    _doc?.dispose();
    super.dispose();
  }

  void _onPrefs() {
    _session.apply();
    setState(() {});
  }

  Future<void> _loadMarks() async {
    final b = await widget.repo.bookmarks(widget.book.id);
    if (mounted) setState(() => _marked = b.map((e) => e.location).toSet());
  }

  void _onPage(int page) {
    if (page == _page) return;
    setState(() => _page = page);
    _save.run(() => widget.repo.saveProgress(widget.book.id,
        location: '$page', progress: _progress));
  }

  /// A jump the reader asked for (contents, bookmark, slider): reading
  /// aloud carries on from the new page.
  void _jump(int page) {
    _goTo(page);
    readAloudFollow();
  }

  void _goTo(int page) {
    page = page.clamp(1, _count);
    if (_mode == PdfMode.pages) {
      _pages?.jumpToPage(page - 1);
    } else if (_viewer.isReady) {
      _viewer.goToPage(pageNumber: page, duration: Duration.zero);
    }
    _onPage(page);
  }

  void _turn(int delta) {
    final p = _pages;
    if (p == null || !p.hasClients) return;
    final target = _page - 1 + delta;
    if (target < 0 || target >= _count) return;
    p.animateToPage(target,
        duration: const Duration(milliseconds: 220), curve: Curves.easeOut);
  }

  /// Pages only turn with the arrows; a tap anywhere shows/hides controls.
  void _onTap(TapUpDetails d) {
    if (_penMode || _ink.stylusBusy.value) return;
    setState(() => _chrome = !_chrome);
  }

  /// The ‹ › arrows: works in both "Turn pages" and "Scroll down" modes.
  void _arrow(int delta) {
    if (readingAloud) {
      // Jump (no animation) so the narrator starts on the right page.
      final target = _page + delta;
      if (target >= 1 && target <= _count) _jump(target);
    } else if (_mode == PdfMode.pages) {
      _turn(delta);
    } else {
      final target = _page + delta;
      if (target >= 1 && target <= _count) _goTo(target);
    }
  }

  Future<void> _toggleBookmark() async {
    final loc = '$_page';
    if (_marked.contains(loc)) {
      final all = await widget.repo.bookmarks(widget.book.id);
      for (final b in all.where((b) => b.location == loc)) {
        await widget.repo.deleteBookmark(b.id!);
      }
    } else {
      await widget.repo.addBookmark(Bookmark(
          bookId: widget.book.id,
          location: loc,
          label: 'Page $_page',
          progress: _progress,
          createdAt: DateTime.now()));
    }
    await _loadMarks();
  }

  Future<void> _contents() async {
    final doc = _doc;
    if (doc == null) return;
    final entries = <TocEntry>[];
    void walk(List<PdfOutlineNode> nodes, int depth) {
      for (final n in nodes) {
        final dest = n.dest;
        if (dest != null) {
          entries.add(TocEntry(n.title, depth, () => _jump(dest.pageNumber)));
        }
        walk(n.children, depth + 1);
      }
    }

    try {
      walk(await doc.loadOutline(), 0);
    } catch (_) {}
    if (mounted) await showContentsSheet(context, entries);
  }

  void _startPen() {
    pauseReadAloud();
    if (widget.prefs.pdfMode != PdfMode.pages) {
      widget.prefs.pdfMode = PdfMode.pages;
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('Switched to "Turn pages" so you can draw on the page.')));
    }
    _zoom.value = Matrix4.identity();
    _ink.penMode = true;
    setState(() {
      _zoomed = false;
      _chrome = false;
    });
  }

  @override
  ReaderPrefs get hostPrefs => widget.prefs;
  @override
  ReaderSession get hostSession => _session;
  @override
  NarrationSource createNarrationSource() => _PdfNarration(this);

  void _endPen() {
    _ink.penMode = false;
    _ink.flush();
    setState(() {});
  }

  Future<void> _editPageNote(int page) async {
    final existing = _ink.notes[page];
    final text = await showNoteDialog(context,
        initial: existing?.note,
        title: existing == null ? 'Note for page $page' : 'Page $page note');
    if (text == null) return;
    await _ink.saveNote(page, text);
  }

  void _openMarks() {
    showMarksSheet(context,
        isPdf: true,
        loadBookmarks: () => widget.repo.bookmarks(widget.book.id),
        onOpenBookmark: (b) => _jump(int.parse(b.location)),
        onDeleteBookmark: (b) async {
          await widget.repo.deleteBookmark(b.id!);
          await _loadMarks();
        },
        loadAnnotations: () async {
          await _ink.flush();
          return widget.repo.annotations(widget.book.id);
        },
        onOpenAnnotation: (a) => _jump(int.tryParse(a.location) ?? _page),
        onDeleteAnnotation: (a) async {
          await widget.repo.deleteAnnotation(a.id!);
          _ink.forget(a);
        });
  }

  @override
  Widget build(BuildContext context) {
    final theme = widget.prefs.theme;
    return Scaffold(
      // The keyboard (for notes) must not shrink and reflow the page.
      resizeToAvoidBottomInset: false,
        backgroundColor: theme.background,
        body: ReaderChrome(
          visible: _chrome,
          theme: theme,
          title: widget.book.title,
          progress: _progress,
          progressLabel: 'Page $_page of $_count · ${(_progress * 100).round()}%',
          bookmarked: _marked.contains('$_page'),
          seekDivisions: _count > 1 ? _count - 1 : null,
          seekLabel: (v) => 'Page ${(v * (_count - 1)).round() + 1}',
          onSeek: (v) => _jump((v * (_count - 1)).round() + 1),
          onBack: () => Navigator.pop(context),
          onContents: _contents,
          onBookmarks: _openMarks,
          onPen: _doc == null ? null : _startPen,
          onReadAloud: _doc == null
              ? null
              : () {
                  setState(() => _chrome = false);
                  startReadAloud();
                },
          onToggleBookmark: _toggleBookmark,
          onSettings: () =>
              showDisplaySheet(context, prefs: widget.prefs, isEpub: false),
          onPrev: _doc == null ? null : () => _arrow(-1),
          onNext: _doc == null ? null : () => _arrow(1),
          canPrev: _page > 1,
          canNext: _page < _count,
          showArrows: !_penMode,
          child: Stack(children: [
            Positioned.fill(child: _body(theme)),
            readAloudBar(chromeVisible: _chrome, hidden: _penMode),
            if (_penMode)
              Positioned(
                left: 12,
                right: 12,
                bottom: 16 + MediaQuery.paddingOf(context).bottom,
                child: Center(
                  child: InkToolbar(
                    controller: _ink,
                    page: _page,
                    pageCount: _count,
                    onPrev: () => _turn(-1),
                    onNext: () => _turn(1),
                    onNote: () => _editPageNote(_page),
                    onDone: _endPen,
                  ),
                ),
              ),
          ]),
        ),
    );
  }

  Widget _body(PageTheme theme) {
    if (_error != null) {
      return _Message(
          theme: theme,
          text: "Sorry, this PDF couldn't be opened.\nIt may be damaged or password-protected.");
    }
    final doc = _doc;
    if (doc == null) return const Center(child: CircularProgressIndicator());

    final mode = widget.prefs.pdfMode;
    if (mode != _mode) {
      _mode = mode;
      _pages?.dispose();
      _pages = mode == PdfMode.pages ? PageController(initialPage: _page - 1) : null;
      _zoom.value = Matrix4.identity();
      _zoomed = false;
    }

    // Pages are rendered white, then the theme's colour filter turns white
    // into paper / night colours — one cheap GPU pass, no re-rendering.
    // Ink is drawn outside the filter so it keeps its true colours.
    final filter = theme.pdfFilter;
    final night = theme == PageTheme.dark;
    if (mode == PdfMode.scroll) return _scrollMode(theme, filter, night);
    Widget backdrop = const ColoredBox(color: Colors.white);
    if (filter != null) backdrop = ColorFiltered(colorFilter: filter, child: backdrop);
    return Stack(children: [
      Positioned.fill(child: backdrop),
      Positioned.fill(child: _pageMode(doc, filter, night)),
    ]);
  }

  Widget _pageMode(PdfDocument doc, ColorFilter? filter, bool night) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTapUp: _onTap,
      child: PageView.builder(
          controller: _pages,
          // Keeps the neighbouring page rendered so page turns are instant,
          // without rendering the whole book.
          allowImplicitScrolling: true,
          // Pages never turn by swiping, only with the ‹ › arrows, so a
          // stray swipe or a resting palm can't lose the reader's place.
          physics: const NeverScrollableScrollPhysics(),
          itemCount: doc.pages.length,
          onPageChanged: (i) {
            _zoom.value = Matrix4.identity();
            _zoomed = false;
            _onPage(i + 1);
          },
          itemBuilder: (c, i) {
            final page = _pageWithInk(doc, i + 1, filter, night);
            if (i != _page - 1) return page;
            return InteractiveViewer(
              transformationController: _zoom,
              minScale: 1,
              maxScale: 5,
              panEnabled: !_penMode,
              scaleEnabled: !_penMode,
              onInteractionEnd: (_) {
                final z = _zoom.value.getMaxScaleOnAxis() > 1.02;
                if (z != _zoomed) setState(() => _zoomed = z);
              },
              child: page,
            );
          },
        ),
    );
  }

  /// The page image with its ink layer on top, sized exactly to the page so
  /// strokes line up (and zoom) with the text underneath.
  Widget _pageWithInk(PdfDocument doc, int number, ColorFilter? filter, bool night) {
    final pg = doc.pages[number - 1];
    Widget image = PdfPageView(
      document: doc,
      pageNumber: number,
      maximumDpi: 220,
      backgroundColor: Colors.white,
    );
    if (filter != null) image = ColorFiltered(colorFilter: filter, child: image);
    return Center(
      child: AspectRatio(
        aspectRatio: pg.width / pg.height,
        child: Stack(fit: StackFit.expand, children: [
          image,
          InkLayer(page: number, controller: _ink, night: night),
          _NoteBadge(ink: _ink, page: number, onTap: () => _editPageNote(number)),
        ]),
      ),
    );
  }

  Widget _scrollMode(PageTheme theme, ColorFilter? filter, bool night) {
    return PdfViewer.file(
      widget.book.path,
      controller: _viewer,
      initialPageNumber: _page,
      params: PdfViewerParams(
        backgroundColor: filter == null ? Colors.white : theme.background,
        pageImageColorFilter: filter,
        margin: 6,
        pageDropShadow: null,
        onPageChanged: (n) => n == null ? null : _onPage(n),
        onGeneralTap: (ctx, c, d) {
          if (d.type != PdfViewerGeneralTapType.tap) return false;
          setState(() => _chrome = !_chrome);
          return true;
        },
        pageOverlaysBuilder: (ctx, rect, page) => [
          Positioned.fill(
            child: InkLayer(
                page: page.pageNumber,
                controller: _ink,
                night: night,
                interactive: false),
          ),
          _NoteBadge(
              ink: _ink,
              page: page.pageNumber,
              onTap: () => _editPageNote(page.pageNumber)),
        ],
      ),
    );
  }
}

/// Gives the narrator the PDF's text, page by page.
class _PdfNarration implements NarrationSource {
  _PdfNarration(this.s);
  final _PdfReaderScreenState s;
  final _cache = <int, String>{};

  @override
  bool get pdf => true;
  @override
  bool get canPeek => true;

  @override
  Future<String?> pageText(int ahead) async {
    final doc = s._doc;
    final page = s._page + ahead;
    if (doc == null || page < 1 || page > doc.pages.length) return null;
    final cached = _cache[page];
    if (cached != null) return cached;
    String text;
    try {
      text = (await doc.pages[page - 1].loadText())?.fullText ?? '';
    } catch (_) {
      text = '';
    }
    if (_cache.length > 12) _cache.remove(_cache.keys.first);
    return _cache[page] = text;
  }

  @override
  Future<bool> turnNext() async {
    if (!s.mounted || s._page >= s._count) return false;
    s._goTo(s._page + 1);
    return true;
  }
}

/// A small sticky-note button on pages that have a note.
class _NoteBadge extends StatelessWidget {
  const _NoteBadge({required this.ink, required this.page, required this.onTap});
  final InkController ink;
  final int page;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: ink,
        builder: (context, _) {
          if (ink.notes[page] == null) return const SizedBox.shrink();
          return Positioned(
            top: 6,
            right: 6,
            child: Material(
              color: const Color(0xFFFFD54F),
              shape: const CircleBorder(),
              elevation: 3,
              child: IconButton(
                tooltip: 'Page note',
                onPressed: onTap,
                icon: const Icon(Icons.sticky_note_2_rounded, color: Colors.black87),
              ),
            ),
          );
        },
      );
}

class _Message extends StatelessWidget {
  const _Message({required this.theme, required this.text});
  final PageTheme theme;
  final String text;
  @override
  Widget build(BuildContext context) => Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Text(text,
              textAlign: TextAlign.center,
              style: TextStyle(color: theme.foreground, fontSize: 18)),
        ),
      );
}
