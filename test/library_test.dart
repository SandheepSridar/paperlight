import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:paperlight/data/db.dart';
import 'package:paperlight/data/library_repo.dart';
import 'package:paperlight/data/models.dart';
import 'package:paperlight/import/importer.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'helpers.dart';

void main() {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  late Directory tmp;
  late LibraryRepo repo;
  late Importer importer;

  setUp(() async {
    tmp = Directory.systemTemp.createTempSync('pl_lib');
    repo = LibraryRepo(await openAppDatabase(path: '${tmp.path}/test.db'));
    importer = Importer(repo, baseDir: tmp);
  });
  tearDown(() => tmp.deleteSync(recursive: true));

  // Same element type the Android file picker produces.
  Stream<Uint8List> bytes(List<int> b) => Stream.value(Uint8List.fromList(b));

  test('imports EPUB into private storage with metadata and cover', () async {
    expect(await importer.importStream('my_book.epub', bytes(buildEpub())), isTrue);
    final books = await repo.books();
    expect(books, hasLength(1));
    final b = books.single;
    expect(b.title, 'Test Book');
    expect(b.author, 'Ann Author');
    expect(b.format, BookFormat.epub);
    expect(b.path, startsWith(tmp.path));
    expect(File(b.path).existsSync(), isTrue);
    expect(File(b.coverPath!).existsSync(), isTrue);
  });

  test('same file twice is detected as duplicate and not stored', () async {
    final data = buildEpub();
    expect(await importer.importStream('a.epub', bytes(data)), isTrue);
    expect(await importer.importStream('copy of a.epub', bytes(data)), isFalse);
    expect(await repo.books(), hasLength(1));
    expect(Directory('${tmp.path}/books').listSync(), hasLength(1));
  });

  test('rejects unsupported files and broken EPUBs without leaving files', () async {
    expect(() => importer.importStream('notes.txt', bytes([1, 2, 3])),
        throwsFormatException);
    await expectLater(importer.importStream('bad.epub', bytes([1, 2, 3])),
        throwsA(anything));
    expect(await repo.books(), isEmpty);
    final dir = Directory('${tmp.path}/books');
    expect(dir.existsSync() ? dir.listSync() : [], isEmpty);
  });

  test('progress, bookmarks and delete', () async {
    await importer.importStream('x.epub', bytes(buildEpub()));
    final b = (await repo.books()).single;
    await repo.saveProgress(b.id, location: 'epubcfi(/6/4)', progress: 0.42);
    final r = (await repo.byId(b.id))!;
    expect(r.location, 'epubcfi(/6/4)');
    expect(r.progress, closeTo(0.42, 1e-9));

    await repo.addBookmark(Bookmark(
        bookId: b.id, location: 'c', label: 'L', progress: .4, createdAt: DateTime.now()));
    expect(await repo.bookmarks(b.id), hasLength(1));

    await repo.delete(r);
    expect(await repo.books(), isEmpty);
    expect(await repo.bookmarks(b.id), isEmpty); // cascade
    expect(File(r.path).existsSync(), isFalse);
  });
}
