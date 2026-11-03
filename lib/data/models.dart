enum BookFormat { pdf, epub }

class Book {
  Book({
    required this.id,
    required this.title,
    required this.author,
    required this.format,
    required this.path,
    required this.hash,
    required this.addedAt,
    this.coverPath,
    this.progress = 0,
    this.location,
    this.lastOpened,
  });

  final String id;
  final String title;
  final String? author;
  final BookFormat format;

  /// Absolute path of the app-private copy of the book.
  final String path;
  final String hash;
  final String? coverPath;

  /// 0..1 through the book.
  final double progress;

  /// PDF: page number. EPUB: CFI string.
  final String? location;
  final DateTime addedAt;
  final DateTime? lastOpened;

  int get percent => (progress * 100).round().clamp(0, 100);

  Map<String, Object?> toRow() => {
        'id': id,
        'title': title,
        'author': author,
        'format': format.name,
        'path': path,
        'hash': hash,
        'cover_path': coverPath,
        'progress': progress,
        'location': location,
        'added_at': addedAt.millisecondsSinceEpoch,
        'last_opened': lastOpened?.millisecondsSinceEpoch,
      };

  factory Book.fromRow(Map<String, Object?> r) => Book(
        id: r['id'] as String,
        title: r['title'] as String,
        author: r['author'] as String?,
        format: BookFormat.values.byName(r['format'] as String),
        path: r['path'] as String,
        hash: r['hash'] as String,
        coverPath: r['cover_path'] as String?,
        progress: (r['progress'] as num?)?.toDouble() ?? 0,
        location: r['location'] as String?,
        addedAt: DateTime.fromMillisecondsSinceEpoch(r['added_at'] as int),
        lastOpened: r['last_opened'] == null
            ? null
            : DateTime.fromMillisecondsSinceEpoch(r['last_opened'] as int),
      );
}

class Bookmark {
  Bookmark({
    this.id,
    required this.bookId,
    required this.location,
    required this.label,
    required this.progress,
    required this.createdAt,
  });

  final int? id;
  final String bookId;
  final String location;
  final String label;
  final double progress;
  final DateTime createdAt;

  Map<String, Object?> toRow() => {
        if (id != null) 'id': id,
        'book_id': bookId,
        'location': location,
        'label': label,
        'progress': progress,
        'created_at': createdAt.millisecondsSinceEpoch,
      };

  factory Bookmark.fromRow(Map<String, Object?> r) => Bookmark(
        id: r['id'] as int,
        bookId: r['book_id'] as String,
        location: r['location'] as String,
        label: r['label'] as String,
        progress: (r['progress'] as num).toDouble(),
        createdAt: DateTime.fromMillisecondsSinceEpoch(r['created_at'] as int),
      );
}
