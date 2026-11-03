import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';

const dbVersion = 2;

/// Opens (and migrates) the app database.
Future<Database> openAppDatabase({String? path, int version = dbVersion}) async {
  final dbPath = path ?? p.join(await getDatabasesPath(), 'paperlight.db');
  return openDatabase(
    dbPath,
    version: version,
    onConfigure: (db) => db.execute('PRAGMA foreign_keys = ON'),
    onCreate: (db, v) async {
      await _createV1(db);
      if (v >= 2) await _createV2(db);
    },
    onUpgrade: (db, from, to) async {
      if (from < 2 && to >= 2) await _createV2(db);
    },
  );
}

Future<void> _createV1(Database db) async {
  await db.execute('''
    CREATE TABLE books(
      id TEXT PRIMARY KEY,
      title TEXT NOT NULL,
      author TEXT,
      format TEXT NOT NULL,
      path TEXT NOT NULL,
      hash TEXT NOT NULL UNIQUE,
      cover_path TEXT,
      progress REAL NOT NULL DEFAULT 0,
      location TEXT,
      epub_locations TEXT,
      added_at INTEGER NOT NULL,
      last_opened INTEGER
    )''');
  await db.execute('''
    CREATE TABLE bookmarks(
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      book_id TEXT NOT NULL REFERENCES books(id) ON DELETE CASCADE,
      location TEXT NOT NULL,
      label TEXT NOT NULL,
      progress REAL NOT NULL,
      created_at INTEGER NOT NULL
    )''');
  await db.execute('CREATE INDEX idx_bookmarks_book ON bookmarks(book_id)');
}

/// v2 (app 1.1): highlights, underlines, notes and PDF ink.
Future<void> _createV2(Database db) async {
  await db.execute('''
    CREATE TABLE annotations(
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      book_id TEXT NOT NULL REFERENCES books(id) ON DELETE CASCADE,
      kind TEXT NOT NULL,
      location TEXT NOT NULL,
      color INTEGER,
      excerpt TEXT,
      note TEXT,
      data TEXT,
      progress REAL NOT NULL,
      created_at INTEGER NOT NULL,
      updated_at INTEGER NOT NULL
    )''');
  await db.execute(
      'CREATE INDEX idx_annotations_book ON annotations(book_id, kind, location)');
}
