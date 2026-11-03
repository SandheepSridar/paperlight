import 'package:flutter/material.dart';
import 'package:pdfrx/pdfrx.dart';

import '../../app/prefs.dart';
import '../../app/theme.dart';
import '../../data/library_repo.dart';
import '../../data/models.dart';
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

class _PdfReaderScreenState extends State<PdfReaderScreen> {
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

  int get _count => _doc?.pages.length ?? 1;
  double get _progress => _count <= 1 ? 1 : (_page - 1) / (_count - 1);

  @override
  void initState() {
    super.initState();
    _session.begin();
    widget.prefs.addListener(_onPrefs);
    _life = AppLifecycleListener(onPause: _save.flush, onHide: _save.flush);
    widget.repo.markOpened(widget.book.id);
    _loadMarks();
    PdfDocument.openFile(widget.book.path).then((d) {
      if (!mounted) return d.dispose();
      setState(() {
        _doc = d;
        _page = _page.clamp(1, d.pages.length);
      });
    }, onError: (e) => mounted ? setState(() => _error = e) : null);
  }

  @override
  void dispose() {
    _save.flush();
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

  /// Left third = back, right third = forward, middle = show/hide controls.
  void _onTap(TapUpDetails d) {
    final w = context.size?.width ?? 1;
    final x = d.localPosition.dx / w;
    if (_chrome) {
      setState(() => _chrome = false);
    } else if (x < 0.3 && !_zoomed) {
      _turn(-1);
    } else if (x > 0.7 && !_zoomed) {
      _turn(1);
    } else {
      setState(() => _chrome = true);
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
          entries.add(TocEntry(n.title, depth, () => _goTo(dest.pageNumber)));
        }
        walk(n.children, depth + 1);
      }
    }

    try {
      walk(await doc.loadOutline(), 0);
    } catch (_) {}
    if (mounted) await showContentsSheet(context, entries);
  }

  @override
  Widget build(BuildContext context) {
    final theme = widget.prefs.theme;
    return Scaffold(
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
          onSeek: (v) => _goTo((v * (_count - 1)).round() + 1),
          onBack: () => Navigator.pop(context),
          onContents: _contents,
          onBookmarks: () => showBookmarksSheet(context,
              load: () => widget.repo.bookmarks(widget.book.id),
              onOpen: (b) => _goTo(int.parse(b.location)),
              onDelete: (b) async {
                await widget.repo.deleteBookmark(b.id!);
                await _loadMarks();
              }),
          onToggleBookmark: _toggleBookmark,
          onSettings: () =>
              showDisplaySheet(context, prefs: widget.prefs, isEpub: false),
          child: _body(theme),
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

    // The page is rendered white, then the theme's colour filter turns white
    // into paper / night colours — one cheap GPU pass, no re-rendering.
    final filter = theme.pdfFilter;
    // The white backdrop must be inside the filter, or the margins around
    // the page stay bright white in Night mode.
    Widget content = ColoredBox(
      color: Colors.white,
      child: mode == PdfMode.pages ? _pageMode(doc) : _scrollMode(),
    );
    if (filter != null) content = ColorFiltered(colorFilter: filter, child: content);
    return content;
  }

  Widget _pageMode(PdfDocument doc) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTapUp: _onTap,
      child: PageView.builder(
        controller: _pages,
        // Keeps the neighbouring page rendered so page turns are instant,
        // without rendering the whole book.
        allowImplicitScrolling: true,
        physics: _zoomed
            ? const NeverScrollableScrollPhysics()
            : const PageScrollPhysics(),
        itemCount: doc.pages.length,
        onPageChanged: (i) {
          _zoom.value = Matrix4.identity();
          _zoomed = false;
          _onPage(i + 1);
        },
        itemBuilder: (c, i) {
          final page = PdfPageView(
            document: doc,
            pageNumber: i + 1,
            maximumDpi: 220,
            backgroundColor: Colors.white,
          );
          if (i != _page - 1) return page;
          return InteractiveViewer(
            transformationController: _zoom,
            minScale: 1,
            maxScale: 5,
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

  Widget _scrollMode() {
    return PdfViewer.file(
      widget.book.path,
      controller: _viewer,
      initialPageNumber: _page,
      params: PdfViewerParams(
        backgroundColor: Colors.white,
        margin: 6,
        pageDropShadow: null,
        onPageChanged: (n) => n == null ? null : _onPage(n),
        onGeneralTap: (ctx, c, d) {
          if (d.type != PdfViewerGeneralTapType.tap) return false;
          setState(() => _chrome = !_chrome);
          return true;
        },
      ),
    );
  }
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
