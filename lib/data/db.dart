import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';

/// Opens (and migrates) the app database.
Future<Database> openAppDatabase({String? path}) async {
  final dbPath = path ?? p.join(await getDatabasesPath(), 'paperlight.db');
  return openDatabase(
    dbPath,
    version: 1,
    onConfigure: (db) => db.execute('PRAGMA foreign_keys = ON'),
    onCreate: (db, _) async {
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
    },
  );
}
