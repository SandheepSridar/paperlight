import 'dart:io';
import 'dart:isolate';

import 'package:crypto/crypto.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:pdfrx/pdfrx.dart';
import 'package:uuid/uuid.dart';

import '../data/library_repo.dart';
import '../data/models.dart';
import 'epub_meta.dart';

class ImportReport {
  int added = 0;
  int duplicates = 0;
  final List<String> failed = [];

  String get message {
    final parts = <String>[
      if (added > 0) 'Added $added book${added == 1 ? '' : 's'}',
      if (duplicates > 0)
        '$duplicates already in your library',
      if (failed.isNotEmpty) "Couldn't open: ${failed.join(', ')}",
    ];
    return parts.isEmpty ? 'No books added' : parts.join(' · ');
  }
}

/// Copies user-chosen files into app-private storage and records them.
/// The app never scans device storage: only what the user picks appears.
class Importer {
  Importer(this.repo, {Directory? baseDir}) : _base = baseDir;

  final LibraryRepo repo;
  Directory? _base;

  Future<Directory> _dir(String name) async {
    _base ??= await getApplicationDocumentsDirectory();
    final d = Directory(p.join(_base!.path, name));
    await d.create(recursive: true);
    return d;
  }

  /// Opens the system file chooser. Returns null if the user cancelled.
  Future<ImportReport?> pickAndImport() async {
    final files = await FilePicker.pickFiles(
      dialogTitle: 'Choose books',
      type: FileType.custom,
      allowedExtensions: const ['pdf', 'epub'],
    );
    if (files.isEmpty) return null;
    final report = ImportReport();
    for (final f in files) {
      try {
        final result = await importStream(f.name, f.xFile.openRead());
        result ? report.added++ : report.duplicates++;
      } catch (e, st) {
        debugPrint('Paperlight: import failed for ${f.name}: $e\n$st');
        report.failed.add(f.name);
      }
    }
    try {
      await FilePicker.clearTemporaryFiles();
    } catch (_) {}
    return report;
  }

  /// Imports one file. Returns false if it's a duplicate. Throws if the file
  /// isn't a readable PDF/EPUB.
  Future<bool> importStream(String name, Stream<List<int>> data) async {
    final ext = p.extension(name).toLowerCase();
    final format = switch (ext) {
      '.pdf' => BookFormat.pdf,
      '.epub' => BookFormat.epub,
      _ => throw FormatException('Unsupported file: $name'),
    };

    final id = const Uuid().v4();
    final dest = File(p.join((await _dir('books')).path, '$id$ext'));
    // addStream (not pipe): the picker yields Stream<Uint8List>, which
    // pipe() rejects at runtime when the sink is typed List<int>.
    final sink = dest.openWrite();
    try {
      await sink.addStream(data);
    } finally {
      await sink.close();
    }

    try {
      final hash = await Isolate.run(() => _sha256(dest.path));
      if (await repo.byHash(hash) != null) {
        await dest.delete();
        return false;
      }

      String title = _titleFromFileName(name);
      String? author;
      Uint8List? cover;
      if (format == BookFormat.epub) {
        final path = dest.path;
        final meta = await Isolate.run(() {
          final m = readEpubMeta(path);
          final c = m.coverBytes == null ? null : _toThumb(m.coverBytes!);
          return EpubMeta(title: m.title, author: m.author, coverBytes: c);
        });
        title = meta.title ?? title;
        author = meta.author;
        cover = meta.coverBytes;
      } else {
        cover = await _pdfCover(dest.path);
      }

      String? coverPath;
      if (cover != null) {
        final c = File(p.join((await _dir('covers')).path, '$id.jpg'));
        await c.writeAsBytes(cover);
        coverPath = c.path;
      }

      await repo.insert(Book(
        id: id,
        title: title,
        author: author,
        format: format,
        path: dest.path,
        hash: hash,
        coverPath: coverPath,
        addedAt: DateTime.now(),
      ));
      return true;
    } catch (_) {
      if (await dest.exists()) await dest.delete();
      rethrow;
    }
  }

  /// Renders page 1 once at import; the library never opens PDFs again.
  Future<Uint8List?> _pdfCover(String path) async {
    final doc = await PdfDocument.openFile(path);
    try {
      if (doc.pages.isEmpty) return null;
      final page = doc.pages.first;
      const w = 360;
      final h = (w * page.height / page.width).round().clamp(1, 1200);
      final image = await page.render(
          width: w, height: h, fullWidth: w.toDouble(), fullHeight: h.toDouble(),
          backgroundColor: 0xffffffff);
      if (image == null) return null;
      final pixels = Uint8List.fromList(image.pixels);
      image.dispose();
      return await Isolate.run(() => img.encodeJpg(
          img.Image.fromBytes(
              width: w, height: h, bytes: pixels.buffer,
              numChannels: 4, order: img.ChannelOrder.bgra),
          quality: 80));
    } finally {
      await doc.dispose();
    }
  }
}

Future<String> _sha256(String path) async =>
    (await sha256.bind(File(path).openRead()).first).toString();

Uint8List? _toThumb(Uint8List bytes) {
  final decoded = img.decodeImage(bytes);
  if (decoded == null) return null;
  final small =
      decoded.width > 360 ? img.copyResize(decoded, width: 360) : decoded;
  return img.encodeJpg(small, quality: 80);
}

String _titleFromFileName(String name) {
  final base = p.basenameWithoutExtension(name)
      .replaceAll(RegExp(r'[_\-.]+'), ' ')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
  return base.isEmpty ? 'Untitled' : base;
}
