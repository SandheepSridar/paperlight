import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive_io.dart';
import 'package:path/path.dart' as p;
import 'package:xml/xml.dart';

class EpubMeta {
  EpubMeta({this.title, this.author, this.coverBytes});
  final String? title;
  final String? author;
  final Uint8List? coverBytes;
}

/// Reads title, author and cover image out of an EPUB without loading the
/// whole book: only container.xml, the OPF and the cover entry are inflated.
/// Pure Dart, so it can run inside an isolate. Throws [FormatException] if
/// the file isn't an EPUB.
EpubMeta readEpubMeta(String path) {
  final input = InputFileStream(path);
  try {
    final archive = ZipDecoder().decodeStream(input);
    try {
      return _parse(archive);
    } finally {
      archive.clearSync();
    }
  } finally {
    input.closeSync();
  }
}

EpubMeta _parse(Archive archive) {
  String? text(String name) {
    final f = archive.findFile(name);
    final bytes = f?.readBytes();
    return bytes == null ? null : utf8.decode(bytes, allowMalformed: true);
  }

  final container = text('META-INF/container.xml');
  if (container == null) {
    throw const FormatException('Not an EPUB: META-INF/container.xml missing');
  }
  final opfPath = XmlDocument.parse(container)
      .findAllElements('rootfile')
      .map((e) => e.getAttribute('full-path'))
      .whereType<String>()
      .firstOrNull;
  if (opfPath == null) return EpubMeta();
  final opfText = text(opfPath);
  if (opfText == null) return EpubMeta();

  final opf = XmlDocument.parse(opfText);
  String? dc(String local) => opf.descendants
      .whereType<XmlElement>()
      .where((e) => e.name.local == local)
      .map((e) => e.innerText.trim())
      .where((s) => s.isNotEmpty)
      .firstOrNull;

  final items = opf.descendants
      .whereType<XmlElement>()
      .where((e) => e.name.local == 'item')
      .toList();

  // EPUB 3: properties="cover-image". EPUB 2: <meta name="cover" content="id">.
  XmlElement? coverItem = items
      .where((e) => (e.getAttribute('properties') ?? '').contains('cover-image'))
      .firstOrNull;
  if (coverItem == null) {
    final coverId = opf.descendants
        .whereType<XmlElement>()
        .where((e) => e.name.local == 'meta' && e.getAttribute('name') == 'cover')
        .map((e) => e.getAttribute('content'))
        .firstOrNull;
    if (coverId != null) {
      coverItem = items.where((e) => e.getAttribute('id') == coverId).firstOrNull;
    }
  }
  coverItem ??= items
      .where((e) =>
          (e.getAttribute('media-type') ?? '').startsWith('image/') &&
          '${e.getAttribute('id')}${e.getAttribute('href')}'
              .toLowerCase()
              .contains('cover'))
      .firstOrNull;

  Uint8List? cover;
  final href = coverItem?.getAttribute('href');
  if (href != null) {
    final full = p.url.normalize(p.url.join(p.url.dirname(opfPath), Uri.decodeFull(href)));
    cover = archive.findFile(full)?.readBytes();
  }
  return EpubMeta(title: dc('title'), author: dc('creator'), coverBytes: cover);
}
