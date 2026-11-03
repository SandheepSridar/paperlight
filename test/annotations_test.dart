import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:paperlight/data/db.dart';
import 'package:paperlight/data/library_repo.dart';
import 'package:paperlight/data/models.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  late Directory tmp;
  setUp(() => tmp = Directory.systemTemp.createTempSync('pl_ann'));
  tearDown(() => tmp.deleteSync(recursive: true));

  Book book(String id) => Book(
        id: id,
        title: 'Book $id',
        author: null,
        format: BookFormat.pdf,
        path: '${tmp.path}/$id.pdf',
        hash: 'hash-$id',
        addedAt: DateTime(2026),
      );

  test('upgrading a 1.0 database keeps books and bookmarks', () async {
    final path = '${tmp.path}/up.db';
    final v1 = await openAppDatabase(path: path, version: 1);
    final repo1 = LibraryRepo(v1);
    await repo1.insert(book('a'));
    await repo1.saveProgress('a', location: '12', progress: 0.4);
    await repo1.addBookmark(Bookmark(
        bookId: 'a',
        location: '12',
        label: 'Page 12',
        progress: 0.4,
        createdAt: DateTime(2026)));
    await v1.close();

    final v2 = await openAppDatabase(path: path);
    final repo = LibraryRepo(v2);
    final b = (await repo.books()).single;
    expect(b.location, '12');
    expect(b.progress, closeTo(0.4, 1e-9));
    expect(await repo.bookmarks('a'), hasLength(1));
    // New table works after the upgrade.
    await repo.saveAnnotation(Annotation(
        bookId: 'a',
        kind: AnnotationKind.highlight,
        location: 'epubcfi(/6/4!/4/2,/1:0,/1:5)',
        progress: 0.1,
        createdAt: DateTime(2026),
        color: 0xFFFFD54F,
        excerpt: 'Hello'));
    expect(await repo.annotations('a'), hasLength(1));
    await v2.close();
  });

  test('annotations: add, update, delete, cascade with book', () async {
    final db = await openAppDatabase(path: '${tmp.path}/a.db');
    final repo = LibraryRepo(db);
    final bk = book('b');
    await repo.insert(bk);

    final h = await repo.saveAnnotation(Annotation(
        bookId: 'b',
        kind: AnnotationKind.highlight,
        location: 'cfi-2',
        progress: 0.5,
        createdAt: DateTime(2026),
        color: 1,
        excerpt: 'later'));
    await repo.saveAnnotation(Annotation(
        bookId: 'b',
        kind: AnnotationKind.underline,
        location: 'cfi-1',
        progress: 0.2,
        createdAt: DateTime(2026)));
    expect(h.id, isNotNull);

    var all = await repo.annotations('b');
    expect(all.map((a) => a.location), ['cfi-1', 'cfi-2'], reason: 'reading order');

    await repo.saveAnnotation(h.copyWith(note: 'my thought', color: 2));
    all = await repo.annotations('b');
    final updated = all.firstWhere((a) => a.id == h.id);
    expect(updated.note, 'my thought');
    expect(updated.color, 2);
    expect(updated.hasNote, isTrue);

    await repo.deleteAnnotation(h.id!);
    expect(await repo.annotations('b'), hasLength(1));

    await repo.delete(bk);
    expect(await repo.annotations('b'), isEmpty);
    await db.close();
  });

  test('ink: one row per page, empty page deletes the row', () async {
    final db = await openAppDatabase(path: '${tmp.path}/i.db');
    final repo = LibraryRepo(db);
    await repo.insert(book('c'));
    final stroke = InkStroke(
        tool: InkTool.pen, color: 0xFF1A1A1A, width: 0.003, points: [0.1, 0.2, 0.3, 0.4]);

    final row = await repo.saveInk('c', 3, 11, [stroke]);
    expect(row!.location, '3');
    expect(row.progress, closeTo(0.2, 1e-9));
    await repo.saveInk('c', 3, 11, [stroke, stroke], existing: row);
    final again = await repo.inkForPage('c', 3);
    expect(again!.id, row.id);
    expect(InkStroke.decodeAll(again.data), hasLength(2));
    expect(await repo.annotations('c'), hasLength(1));

    expect(await repo.saveInk('c', 3, 11, const []), isNull);
    expect(await repo.inkForPage('c', 3), isNull);
    await db.close();
  });

  test('ink strokes round-trip through JSON in page coordinates', () {
    final s = InkStroke(
        tool: InkTool.marker,
        color: 0x5564B5F6,
        width: 0.024,
        points: [0.123456789, 0.5, 1.0, 0.0]);
    final back = InkStroke.decodeAll(InkStroke.encodeAll([s])).single;
    expect(back.tool, InkTool.marker);
    expect(back.color, 0x5564B5F6);
    expect(back.width, 0.024);
    expect(back.length, 2);
    expect(back.points[0], closeTo(0.1235, 1e-9));
    expect(back.points.every((v) => v >= 0 && v <= 1), isTrue);
    expect(InkStroke.decodeAll(null), isEmpty);
  });
}
