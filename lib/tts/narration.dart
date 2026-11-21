/// Turns raw page text into natural-sounding speech chunks.
///
/// A neural voice sounds best when it is given whole sentences (so its
/// intonation can follow the sentence) and when the pauses between them match
/// the shape of the text: short between sentences, longer between paragraphs,
/// longest around headings. PDF text also needs repairing first: lines are
/// hard-wrapped, words are hyphenated across lines, and page numbers and
/// running headers sit in the middle of the prose.
library;

/// One piece of text to speak, followed by a pause.
class Utterance {
  const Utterance(this.text, this.pauseAfter, {this.heading = false});
  final String text;
  final Duration pauseAfter;
  final bool heading;

  @override
  String toString() => 'Utterance("$text", ${pauseAfter.inMilliseconds}ms)';
}

/// A page ready to be read: its utterances, plus the start of a sentence
/// that runs on to the next page ([carry]). The carry is spoken together
/// with the next page's first words so the sentence isn't broken in two.
class NarratedPage {
  const NarratedPage(this.utterances, this.carry);
  final List<Utterance> utterances;
  final String carry;
}

// Pauses added after each chunk. The voice's own silence at the ends of a
// clip is trimmed first, so these are the whole gap you hear.
const sentencePause = Duration(milliseconds: 250);
const paragraphPause = Duration(milliseconds: 600);
const headingPause = Duration(milliseconds: 1000);

/// Builds the utterances for one page.
///
/// [carry] is the unfinished sentence from the previous page. [neighbours]
/// (PDF only) is the raw text of the pages before and after, used to spot
/// running headers and footers that repeat from page to page.
NarratedPage narratePage(
  String raw, {
  required bool pdf,
  String carry = '',
  List<String> neighbours = const [],
  int maxChunk = 220,
}) {
  var paragraphs = pdf
      ? pdfParagraphs(raw, neighbours: neighbours)
      : textParagraphs(raw);
  paragraphs = paragraphs.map(normalise).where((p) => p.isNotEmpty).toList();

  if (carry.isNotEmpty) {
    if (paragraphs.isEmpty) {
      paragraphs = [carry];
    } else {
      paragraphs[0] = joinAcrossBreak(carry, paragraphs[0]);
    }
  }

  // A sentence that is still open at the bottom of the page runs on to the
  // next one: hold it back and speak it there in one piece.
  var nextCarry = '';
  if (paragraphs.isNotEmpty && !isHeading(paragraphs.last)) {
    final last = paragraphs.last;
    final sentences = splitSentences(last);
    if (sentences.isNotEmpty && !endsSentence(sentences.last)) {
      nextCarry = sentences.removeLast();
      if (sentences.isEmpty) {
        paragraphs.removeLast();
      } else {
        paragraphs[paragraphs.length - 1] = sentences.join(' ');
      }
    }
  }

  return NarratedPage(buildUtterances(paragraphs, maxChunk: maxChunk), nextCarry);
}

/// Groups sentences into chunks of up to [maxChunk] characters. Chunks never
/// cross a paragraph, so each paragraph ends with a proper pause.
List<Utterance> buildUtterances(List<String> paragraphs, {int maxChunk = 220}) {
  final out = <Utterance>[];
  for (var i = 0; i < paragraphs.length; i++) {
    final para = paragraphs[i];
    final nextIsHeading = i + 1 < paragraphs.length && isHeading(paragraphs[i + 1]);
    if (isHeading(para)) {
      out.add(Utterance(para, headingPause, heading: true));
      continue;
    }
    final pieces = <String>[];
    for (final s in splitSentences(para)) {
      pieces.addAll(s.length > maxChunk * 1.4 ? splitLong(s, maxChunk) : [s]);
    }
    var buf = '';
    for (final s in pieces) {
      if (buf.isNotEmpty && buf.length + 1 + s.length > maxChunk) {
        out.add(Utterance(buf, sentencePause));
        buf = s;
      } else {
        buf = buf.isEmpty ? s : '$buf $s';
      }
    }
    if (buf.isNotEmpty) {
      out.add(Utterance(buf, nextIsHeading ? headingPause : paragraphPause));
    }
  }
  return out;
}

// ------------------------------------------------------------ paragraphs

/// EPUB / reflowable text: every line break is already a paragraph break.
List<String> textParagraphs(String raw) => raw
    .replaceAll('\r\n', '\n')
    .split(RegExp(r'\n+'))
    .map((l) => l.trim())
    .where((l) => l.isNotEmpty)
    .toList();

final _pageNumber = RegExp(
    r'^(page\s+)?(\d{1,4}|[ivxlcdm]{1,7})(\s*(of|/)\s*\d{1,4})?$',
    caseSensitive: false);

/// Normalised key for comparing header/footer lines between pages
/// (page numbers inside them change, so digits are ignored).
String _lineKey(String l) =>
    l.toLowerCase().replaceAll(RegExp(r'[\d\s]+'), ' ').trim();

List<String> _lines(String raw) => raw
    .replaceAll('\r\n', '\n')
    .replaceAll('\r', '\n')
    .split('\n')
    .map((l) => l.replaceAll(RegExp(r'[ \t ]+'), ' ').trim())
    .toList();

/// PDF text: rebuilds paragraphs from hard-wrapped lines, rejoins hyphenated
/// words, and drops page numbers and running headers / footers.
List<String> pdfParagraphs(String raw, {List<String> neighbours = const []}) {
  var lines = _lines(raw);

  // Running headers and footers: short lines at the top or bottom of the page
  // that also appear at the top or bottom of a neighbouring page.
  final edgeKeys = <String>{};
  for (final n in neighbours) {
    final nl = _lines(n).where((l) => l.isNotEmpty).toList();
    for (final l in [...nl.take(2), ...nl.reversed.take(2)]) {
      if (l.length <= 80) edgeKeys.add(_lineKey(l));
    }
  }
  edgeKeys.remove('');
  final nonEmpty = [
    for (var i = 0; i < lines.length; i++)
      if (lines[i].isNotEmpty) i
  ];
  final edges = {...nonEmpty.take(2), ...nonEmpty.reversed.take(2)};
  lines = [
    for (var i = 0; i < lines.length; i++)
      if (!(edges.contains(i) &&
          (_pageNumber.hasMatch(lines[i]) ||
              (lines[i].length <= 80 && edgeKeys.contains(_lineKey(lines[i]))))))
        lines[i]
  ];

  // Typical full line length, to tell a paragraph's short last line apart.
  final lengths = lines.where((l) => l.isNotEmpty).map((l) => l.length).toList()
    ..sort();
  final typical = lengths.isEmpty ? 0 : lengths[(lengths.length * 0.75).floor().clamp(0, lengths.length - 1)];

  final paragraphs = <String>[];
  var buf = '';
  void flush() {
    if (buf.trim().isNotEmpty) paragraphs.add(buf.trim());
    buf = '';
  }

  for (var i = 0; i < lines.length; i++) {
    final line = lines[i];
    if (line.isEmpty) {
      flush();
      continue;
    }
    final short = typical > 0 && line.length < typical * 0.7;
    final headingLike = short && isHeading(line) && line.length <= 60;
    if (headingLike && buf.isEmpty) {
      paragraphs.add(line);
      continue;
    }
    buf = buf.isEmpty ? line : joinAcrossBreak(buf, line);
    if (short && endsSentence(line)) flush();
  }
  flush();
  return paragraphs;
}

/// Joins two pieces of text that were split by a line or page break,
/// repairing a word hyphenated across the break ("exam-" + "ple").
String joinAcrossBreak(String a, String b) {
  final m = RegExp(r'([A-Za-z])[-­]$').firstMatch(a);
  if (m != null && b.isNotEmpty && RegExp(r'^[a-z]').hasMatch(b)) {
    return a.substring(0, a.length - 1) + b;
  }
  return '$a $b';
}

// ------------------------------------------------------------ cleanup

/// Tidies text so the voice reads it smoothly: plain quotes, spoken
/// pauses for dashes, no footnote numbers or stray symbols.
String normalise(String s) {
  s = s
      .replaceAll('­', '') // soft hyphen
      .replaceAll(RegExp('[‘’‛′]'), "'")
      .replaceAll(RegExp('[“”‟″«»]'), '"')
      .replaceAll('…', '...')
      .replaceAll(RegExp('[¹²³⁰-⁹]+'), '') // superscripts
      // Footnote references: [12], or digits glued to the end of a sentence.
      .replaceAll(RegExp(r'\[\d{1,3}\]'), '')
      .replaceAllMapped(RegExp(r'''([a-z][.,;:!?"')])\d{1,3}(?=\s|$)'''), (m) => m[1]!)
      // Dashes used as punctuation become a spoken pause.
      .replaceAll(RegExp(r'\s*(—|–|--)\s*'), ', ')
      .replaceAll(RegExp(r'[*_#~|•·▪►◆]+'), ' ')
      .replaceAll(RegExp(r'\s+'), ' ')
      .replaceAll(RegExp(r' ([,.;:!?])'), r'$1')
      .replaceAll(RegExp(r',\s*,'), ',')
      .trim();
  if (s.startsWith(', ')) s = s.substring(2);
  return s;
}

// ------------------------------------------------------------ sentences

const _abbreviations = {
  'mr', 'mrs', 'ms', 'dr', 'st', 'prof', 'sr', 'jr', 'vs', 'etc', 'e.g',
  'i.e', 'no', 'vol', 'ch', 'fig', 'p', 'pp', 'mt', 'ft', 'gen', 'col',
  'capt', 'lt', 'sgt', 'rev', 'inc', 'ltd', 'co', 'jan', 'feb', 'mar',
  'apr', 'jun', 'jul', 'aug', 'sep', 'sept', 'oct', 'nov', 'dec', 'approx',
  'cf', 'al', 'ed', 'eds', 'est', 'dept', 'univ', 'gov', 'sen', 'rep',
};

final _boundary = RegExp(r'''[.!?]+["')\]]*\s+''');

/// Finds [snippet] (e.g. words the reader selected) in [page], ignoring
/// differences in spacing and line breaks. Returns its offset, or null.
int? locateSnippet(String page, String snippet) {
  final words = snippet.trim().split(RegExp(r'\s+')).where((w) => w.isNotEmpty).take(8).toList();
  while (words.isNotEmpty) {
    final m = RegExp(words.map(RegExp.escape).join(r'\s+')).firstMatch(page);
    if (m != null) return m.start;
    words.removeLast();
  }
  return null;
}

/// Where the sentence containing [offset] begins in raw page text: just
/// after the previous sentence end or line break (used for "read from
/// here").
int sentenceStartBefore(String raw, int offset) {
  offset = offset.clamp(0, raw.length);
  var i = offset;
  while (i > 0) {
    final c = raw[i - 1];
    if (c == '\n') break;
    if ('.!?'.contains(c) && i < raw.length && RegExp(r'\s').hasMatch(raw[i])) {
      // Not after an abbreviation like "Mr." or an initial.
      final word = RegExp(r'([A-Za-z.]+)\.$').firstMatch(raw.substring(0, i))?[1]?.toLowerCase();
      if (c != '.' || word == null || (!_abbreviations.contains(word) && word.length > 1)) break;
    }
    i--;
  }
  while (i < raw.length && RegExp(r'\s').hasMatch(raw[i])) {
    i++;
  }
  return i > offset ? offset : i;
}

/// Splits a paragraph into sentences without breaking on abbreviations
/// ("Mr.", "e.g."), initials ("J. R. Tolkien") or decimals ("3.5").
List<String> splitSentences(String text) {
  final out = <String>[];
  var start = 0;
  for (final m in _boundary.allMatches(text)) {
    final end = m.end;
    if (end >= text.length) break;
    final before = text.substring(start, m.start + 1);
    final word = RegExp(r'([A-Za-z.]+)\.$').firstMatch(before)?[1]?.toLowerCase();
    if (word != null && text[m.start] == '.') {
      if (_abbreviations.contains(word)) continue;
      if (word.length == 1) continue; // an initial
    }
    // The next sentence starts with a capital, a digit or a quote.
    if (!RegExp(r'''^["'(\[]?[A-Z0-9]''').hasMatch(text.substring(end))) continue;
    out.add(text.substring(start, end).trim());
    start = end;
  }
  final rest = text.substring(start).trim();
  if (rest.isNotEmpty) out.add(rest);
  return out;
}

/// Splits an over-long sentence at a natural break (semicolon, colon,
/// comma) so each chunk stays quick to generate.
List<String> splitLong(String s, int max) {
  final out = <String>[];
  var rest = s;
  while (rest.length > max * 1.4) {
    final window = rest.substring(0, max);
    var cut = -1;
    for (final p in [RegExp(r'[;:]\s'), RegExp(r',\s'), RegExp(r'\s')]) {
      final ms = p.allMatches(window).toList();
      if (ms.isNotEmpty && ms.last.start > max * 0.4) {
        cut = ms.last.start + 1;
        break;
      }
    }
    if (cut < 0) cut = max;
    out.add(rest.substring(0, cut).trim());
    rest = rest.substring(cut).trim();
  }
  if (rest.isNotEmpty) out.add(rest);
  return out;
}

final _terminal = RegExp(r'''[.!?:]["')\]]*$|\.\.\.$''');

bool endsSentence(String s) => _terminal.hasMatch(s.trimRight());

/// A short line with no closing punctuation that starts like a title:
/// "Chapter 3", "THE RETURN", "Part Two: Winter".
bool isHeading(String s) {
  final t = s.trim();
  if (t.isEmpty || t.length > 60) return false;
  if (RegExp(r'[.!?,;"]$').hasMatch(t)) return false;
  if (!RegExp(r'^[A-Z0-9IVX]').hasMatch(t)) return false;
  final words = t.split(' ');
  if (words.length > 8) return false;
  // Mostly capitalised words, or an explicit chapter / part label.
  final caps = words.where((w) => RegExp(r'^[A-Z0-9]').hasMatch(w)).length;
  return caps >= (words.length / 2).ceil() ||
      RegExp(r'^(chapter|part|book|prologue|epilogue|section)\b',
              caseSensitive: false)
          .hasMatch(t);
}
