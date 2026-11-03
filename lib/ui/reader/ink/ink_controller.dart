import 'dart:async';

import 'package:flutter/material.dart';

import '../../../data/library_repo.dart';
import '../../../data/models.dart';
import '../annotation_menus.dart';

enum DrawTool { pen, marker, eraser }

/// Holds the ink and page notes of one PDF while it's open, the current
/// pen settings, and undo. Saves changed pages shortly after each stroke.
class InkController extends ChangeNotifier {
  InkController({required this.repo, required this.bookId});

  final LibraryRepo repo;
  final String bookId;
  int pageCount = 1;

  // ---- pen settings
  bool _penMode = false;

  /// Finger drawing (the toolbar is open). The S Pen always draws.
  bool get penMode => _penMode;
  set penMode(bool v) {
    if (v == _penMode) return;
    _penMode = v;
    notifyListeners();
  }

  DrawTool tool = DrawTool.pen;
  Color penColor = penColors.first;
  Color markerColor = highlightColors.first;

  void setTool(DrawTool t) {
    tool = t;
    notifyListeners();
  }

  void setColor(Color c) {
    if (tool == DrawTool.marker) {
      markerColor = c;
    } else {
      penColor = c;
      if (tool == DrawTool.eraser) tool = DrawTool.pen;
    }
    notifyListeners();
  }

  // ---- palm guard: while the S Pen is writing (or hovering), finger
  // touches must not turn the page.
  final stylusBusy = ValueNotifier(false);
  Timer? _stylusTimer;

  void stylusSeen({bool down = false}) {
    _stylusTimer?.cancel();
    stylusBusy.value = true;
    if (!down) {
      _stylusTimer = Timer(const Duration(milliseconds: 900),
          () => stylusBusy.value = false);
    }
  }

  // ---- data
  final Map<int, List<InkStroke>> _strokes = {};
  final Map<int, Annotation> _inkRows = {};
  final Map<int, Annotation> notes = {};
  final Map<int, int> _versions = {};
  final Set<int> _dirty = {};
  final List<_UndoStep> _undo = [];
  final _save = Debouncer(const Duration(milliseconds: 600));
  bool loaded = false;

  Future<void> load() async {
    final all = await repo.annotations(bookId);
    for (final a in all) {
      final page = int.tryParse(a.location);
      if (page == null) continue;
      if (a.kind == AnnotationKind.ink) {
        _inkRows[page] = a;
        try {
          _strokes[page] = InkStroke.decodeAll(a.data);
        } catch (_) {}
      } else if (a.kind == AnnotationKind.note) {
        notes[page] = a;
      }
    }
    loaded = true;
    notifyListeners();
  }

  List<InkStroke> strokes(int page) => _strokes[page] ?? const [];

  /// Bumps whenever a page's strokes change, so its painter knows to repaint.
  int version(int page) => _versions[page] ?? 0;

  bool get canUndo => _undo.isNotEmpty;

  void add(int page, InkStroke s) {
    (_strokes[page] ??= []).add(s);
    _undo.add(_UndoStep(page, s, added: true));
    _changed(page);
  }

  /// Removes every stroke on [page] that passes within [radius] (pixels) of
  /// [at] (pixels), on a page drawn at [size].
  bool eraseAt(int page, Offset at, double radius, Size size) {
    final list = _strokes[page];
    if (list == null || list.isEmpty) return false;
    var any = false;
    for (final s in list.toList()) {
      if (_hits(s, at, radius, size)) {
        final i = list.indexOf(s);
        list.removeAt(i);
        _undo.add(_UndoStep(page, s, added: false, index: i));
        any = true;
      }
    }
    if (any) _changed(page);
    return any;
  }

  void undo() {
    if (_undo.isEmpty) return;
    final step = _undo.removeLast();
    final list = _strokes[step.page] ??= [];
    if (step.added) {
      list.remove(step.stroke);
    } else {
      list.insert(step.index.clamp(0, list.length), step.stroke);
    }
    _changed(step.page);
  }

  void _changed(int page) {
    _versions[page] = version(page) + 1;
    _dirty.add(page);
    _save.run(() => unawaited(flush()));
    notifyListeners();
  }

  Future<void> flush() async {
    _save.flush();
    final pages = _dirty.toList();
    _dirty.clear();
    for (final p in pages) {
      final row = await repo.saveInk(bookId, p, pageCount, strokes(p),
          existing: _inkRows[p]);
      if (row == null) {
        _inkRows.remove(p);
      } else {
        _inkRows[p] = row;
      }
    }
  }

  // ---- page notes
  Future<void> saveNote(int page, String text) async {
    final existing = notes[page];
    if (text.trim().isEmpty) {
      if (existing?.id != null) await repo.deleteAnnotation(existing!.id!);
      notes.remove(page);
    } else if (existing != null) {
      notes[page] = await repo.saveAnnotation(existing.copyWith(note: text));
    } else {
      notes[page] = await repo.saveAnnotation(Annotation(
        bookId: bookId,
        kind: AnnotationKind.note,
        location: '$page',
        progress: pageCount <= 1 ? 0 : (page - 1) / (pageCount - 1),
        createdAt: DateTime.now(),
        note: text,
      ));
    }
    notifyListeners();
  }

  /// Called after the list sheet deleted a row, to keep memory in sync.
  void forget(Annotation a) {
    final page = int.tryParse(a.location);
    if (page == null) return;
    if (a.kind == AnnotationKind.note) {
      notes.remove(page);
    } else if (a.kind == AnnotationKind.ink) {
      _inkRows.remove(page);
      _strokes.remove(page);
      _undo.removeWhere((u) => u.page == page);
      _versions[page] = version(page) + 1;
    }
    notifyListeners();
  }

  @override
  void dispose() {
    _stylusTimer?.cancel();
    stylusBusy.dispose();
    super.dispose();
  }

  static bool _hits(InkStroke s, Offset at, double r, Size size) {
    final pts = s.points;
    final half = s.width * size.width / 2;
    final rr = r + half;
    Offset pt(int i) => Offset(pts[i * 2] * size.width, pts[i * 2 + 1] * size.height);
    if (s.length == 1) return (pt(0) - at).distance <= rr;
    for (var i = 1; i < s.length; i++) {
      if (_segDist(at, pt(i - 1), pt(i)) <= rr) return true;
    }
    return false;
  }

  static double _segDist(Offset p, Offset a, Offset b) {
    final ab = b - a;
    final len2 = ab.dx * ab.dx + ab.dy * ab.dy;
    if (len2 == 0) return (p - a).distance;
    final t = (((p - a).dx * ab.dx + (p - a).dy * ab.dy) / len2).clamp(0.0, 1.0);
    return (p - (a + ab * t)).distance;
  }
}

class _UndoStep {
  _UndoStep(this.page, this.stroke, {required this.added, this.index = 0});
  final int page;
  final InkStroke stroke;
  final bool added;
  final int index;
}
