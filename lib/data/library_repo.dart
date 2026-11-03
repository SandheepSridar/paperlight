import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:sqflite/sqflite.dart';

import 'models.dart';

/// Single source of truth for the library. Notifies listeners when the list
/// of books changes so the library screen can rebuild.
class LibraryRepo extends ChangeNotifier {
  LibraryRepo(this._db);

  final Database _db;

  Future<List<Book>> books() async {
    final rows = await _db.query('books',
        orderBy: 'COALESCE(last_opened, added_at) DESC');
    return rows.map(Book.fromRow).toList();
  }

  Future<Book?> byHash(String hash) async {
    final rows =
        await _db.query('books', where: 'hash = ?', whereArgs: [hash], limit: 1);
    return rows.isEmpty ? null : Book.fromRow(rows.first);
  }

  Future<void> insert(Book book) async {
    await _db.insert('books', book.toRow());
    notifyListeners();
  }

  /// Removes the book row and its files (book copy + cover).
  Future<void> delete(Book book) async {
    await _db.delete('books', where: 'id = ?', whereArgs: [book.id]);
    for (final path in [book.path, book.coverPath]) {
      if (path == null) continue;
      try {
        await File(path).delete();
      } catch (_) {}
    }
    notifyListeners();
  }

  Future<void> markOpened(String id) async {
    await _db.update(
        'books', {'last_opened': DateTime.now().millisecondsSinceEpoch},
        where: 'id = ?', whereArgs: [id]);
    notifyListeners();
  }

  Future<void> saveProgress(String id,
      {required String location, required double progress}) async {
    await _db.update(
        'books', {'location': location, 'progress': progress.clamp(0.0, 1.0)},
        where: 'id = ?', whereArgs: [id]);
    // No notify: the library refreshes when the reader closes.
  }

  Future<Book?> byId(String id) async {
    final rows =
        await _db.query('books', where: 'id = ?', whereArgs: [id], limit: 1);
    return rows.isEmpty ? null : Book.fromRow(rows.first);
  }

  /// Cached epub.js locations so progress % is available instantly.
  Future<String?> epubLocations(String id) async {
    final rows = await _db.query('books',
        columns: ['epub_locations'], where: 'id = ?', whereArgs: [id]);
    return rows.isEmpty ? null : rows.first['epub_locations'] as String?;
  }

  Future<void> saveEpubLocations(String id, String locations) => _db.update(
      'books', {'epub_locations': locations},
      where: 'id = ?', whereArgs: [id]);

  Future<List<Bookmark>> bookmarks(String bookId) async {
    final rows = await _db.query('bookmarks',
        where: 'book_id = ?', whereArgs: [bookId], orderBy: 'progress ASC');
    return rows.map(Bookmark.fromRow).toList();
  }

  Future<void> addBookmark(Bookmark b) => _db.insert('bookmarks', b.toRow());

  Future<void> deleteBookmark(int id) =>
      _db.delete('bookmarks', where: 'id = ?', whereArgs: [id]);

  /// All highlights / underlines / notes / ink for a book, in reading order.
  Future<List<Annotation>> annotations(String bookId) async {
    final rows = await _db.query('annotations',
        where: 'book_id = ?',
        whereArgs: [bookId],
        orderBy: 'progress ASC, created_at ASC');
    return rows.map(Annotation.fromRow).toList();
  }

  /// Inserts or updates; returns the annotation with its id.
  Future<Annotation> saveAnnotation(Annotation a) async {
    if (a.id == null) {
      final id = await _db.insert('annotations', a.toRow());
      return a.copyWith(id: id, updatedAt: a.updatedAt);
    }
    await _db.update('annotations', a.toRow(),
        where: 'id = ?', whereArgs: [a.id]);
    return a;
  }

  Future<void> deleteAnnotation(int id) =>
      _db.delete('annotations', where: 'id = ?', whereArgs: [id]);

  /// The single ink row for a PDF page, if any.
  Future<Annotation?> inkForPage(String bookId, int page) async {
    final rows = await _db.query('annotations',
        where: 'book_id = ? AND kind = ? AND location = ?',
        whereArgs: [bookId, AnnotationKind.ink.name, '$page'],
        limit: 1);
    return rows.isEmpty ? null : Annotation.fromRow(rows.first);
  }

  /// Saves the strokes of a PDF page (deletes the row when empty).
  Future<Annotation?> saveInk(String bookId, int page, int pageCount,
      List<InkStroke> strokes, {Annotation? existing}) async {
    final row = existing ?? await inkForPage(bookId, page);
    if (strokes.isEmpty) {
      if (row?.id != null) await deleteAnnotation(row!.id!);
      return null;
    }
    final data = InkStroke.encodeAll(strokes);
    if (row == null) {
      final now = DateTime.now();
      return saveAnnotation(Annotation(
        bookId: bookId,
        kind: AnnotationKind.ink,
        location: '$page',
        progress: pageCount <= 1 ? 0 : (page - 1) / (pageCount - 1),
        createdAt: now,
        data: data,
      ));
    }
    return saveAnnotation(row.copyWith(data: data));
  }
}

/// Calls [action] at most once per [delay], always with the latest value —
/// keeps progress saves off the hot path of page turning.
class Debouncer {
  Debouncer(this.delay);
  final Duration delay;
  Timer? _t;
  void Function()? _pending;

  void run(void Function() action) {
    _pending = action;
    _t?.cancel();
    _t = Timer(delay, flush);
  }

  void flush() {
    _t?.cancel();
    final a = _pending;
    _pending = null;
    a?.call();
  }
}
