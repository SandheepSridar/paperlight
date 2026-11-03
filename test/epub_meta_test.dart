import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:paperlight/import/epub_meta.dart';

import 'helpers.dart';

void main() {
  late Directory tmp;
  setUp(() => tmp = Directory.systemTemp.createTempSync('pl_meta'));
  tearDown(() => tmp.deleteSync(recursive: true));

  test('reads title, author and url-encoded cover path', () {
    final f = File('${tmp.path}/b.epub')..writeAsBytesSync(buildEpub());
    final m = readEpubMeta(f.path);
    expect(m.title, 'Test Book');
    expect(m.author, 'Ann Author');
    expect(m.coverBytes, isNotNull);
  });

  test('garbage file is rejected', () {
    final f = File('${tmp.path}/b.epub')..writeAsBytesSync([1, 2, 3, 4]);
    expect(() => readEpubMeta(f.path), throwsA(anything));
  });

  test('book without cover', () {
    final f = File('${tmp.path}/b.epub')..writeAsBytesSync(buildEpub(cover: false));
    final m = readEpubMeta(f.path);
    expect(m.title, 'Test Book');
    expect(m.coverBytes, isNull);
  });
}
