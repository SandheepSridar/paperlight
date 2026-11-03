import 'dart:convert';

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

enum AnnotationKind { highlight, underline, ink, note }

/// A highlight, underline or note on an EPUB range (CFI), or ink / a note on
/// a PDF page (location = page number).
class Annotation {
  Annotation({
    this.id,
    required this.bookId,
    required this.kind,
    required this.location,
    required this.progress,
    required this.createdAt,
    DateTime? updatedAt,
    this.color,
    this.excerpt,
    this.note,
    this.data,
  }) : updatedAt = updatedAt ?? createdAt;

  final int? id;
  final String bookId;
  final AnnotationKind kind;
  final String location;
  final double progress;
  final int? color;
  final String? excerpt;
  final String? note;

  /// PDF ink: JSON-encoded list of [InkStroke]s for the page.
  final String? data;
  final DateTime createdAt;
  final DateTime updatedAt;

  bool get hasNote => (note ?? '').trim().isNotEmpty;

  Annotation copyWith({
    int? id,
    int? color,
    String? note,
    String? data,
    DateTime? updatedAt,
  }) =>
      Annotation(
        id: id ?? this.id,
        bookId: bookId,
        kind: kind,
        location: location,
        progress: progress,
        createdAt: createdAt,
        updatedAt: updatedAt ?? DateTime.now(),
        color: color ?? this.color,
        excerpt: excerpt,
        note: note ?? this.note,
        data: data ?? this.data,
      );

  Map<String, Object?> toRow() => {
        if (id != null) 'id': id,
        'book_id': bookId,
        'kind': kind.name,
        'location': location,
        'progress': progress,
        'color': color,
        'excerpt': excerpt,
        'note': note,
        'data': data,
        'created_at': createdAt.millisecondsSinceEpoch,
        'updated_at': updatedAt.millisecondsSinceEpoch,
      };

  factory Annotation.fromRow(Map<String, Object?> r) => Annotation(
        id: r['id'] as int,
        bookId: r['book_id'] as String,
        kind: AnnotationKind.values.byName(r['kind'] as String),
        location: r['location'] as String,
        progress: (r['progress'] as num).toDouble(),
        color: r['color'] as int?,
        excerpt: r['excerpt'] as String?,
        note: r['note'] as String?,
        data: r['data'] as String?,
        createdAt: DateTime.fromMillisecondsSinceEpoch(r['created_at'] as int),
        updatedAt: DateTime.fromMillisecondsSinceEpoch(r['updated_at'] as int),
      );
}

enum InkTool { pen, marker }

/// One freehand stroke on a PDF page. Points are normalised to the page
/// (0..1 on both axes) so ink lines up at any zoom level or screen size.
class InkStroke {
  InkStroke({
    required this.tool,
    required this.color,
    required this.width,
    required this.points,
  });

  final InkTool tool;
  final int color;

  /// Stroke width as a fraction of the page width.
  final double width;

  /// Flat list: x0, y0, x1, y1, ...
  final List<double> points;

  int get length => points.length ~/ 2;

  Map<String, Object?> toJson() => {
        't': tool.name,
        'c': color,
        'w': width,
        // 4 decimals = sub-pixel precision even on a large tablet page.
        'p': [for (final v in points) (v * 10000).round() / 10000],
      };

  factory InkStroke.fromJson(Map<String, Object?> j) => InkStroke(
        tool: InkTool.values.byName(j['t'] as String),
        color: j['c'] as int,
        width: (j['w'] as num).toDouble(),
        points: [for (final v in j['p'] as List) (v as num).toDouble()],
      );

  static String encodeAll(List<InkStroke> strokes) =>
      jsonEncode([for (final s in strokes) s.toJson()]);

  static List<InkStroke> decodeAll(String? data) {
    if (data == null || data.isEmpty) return [];
    final list = jsonDecode(data) as List;
    return [for (final j in list) InkStroke.fromJson(Map<String, Object?>.from(j as Map))];
  }
}
