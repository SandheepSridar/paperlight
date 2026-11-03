import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:image/image.dart' as img;

/// Builds a minimal valid EPUB 3 in memory.
Uint8List buildEpub({String title = 'Test Book', String author = 'Ann Author', bool cover = true}) {
  final a = Archive();
  void add(String name, List<int> data) => a.addFile(ArchiveFile(name, data.length, data));
  add('mimetype', utf8.encode('application/epub+zip'));
  add('META-INF/container.xml', utf8.encode('''<?xml version="1.0"?>
<container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
  <rootfiles><rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/></rootfiles>
</container>'''));
  add('OEBPS/content.opf', utf8.encode('''<?xml version="1.0"?>
<package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="id">
  <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
    <dc:identifier id="id">x</dc:identifier>
    <dc:title>$title</dc:title>
    <dc:creator>$author</dc:creator>
  </metadata>
  <manifest>
    <item id="c1" href="ch1.xhtml" media-type="application/xhtml+xml"/>
    ${cover ? '<item id="cov" href="images/cover%20art.png" media-type="image/png" properties="cover-image"/>' : ''}
  </manifest>
  <spine><itemref idref="c1"/></spine>
</package>'''));
  add('OEBPS/ch1.xhtml', utf8.encode('<html><body><p>Hello</p></body></html>'));
  if (cover) {
    final png = img.encodePng(img.Image(width: 600, height: 900));
    add('OEBPS/images/cover art.png', png);
  }
  return Uint8List.fromList(ZipEncoder().encode(a));
}
