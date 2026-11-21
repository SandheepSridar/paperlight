import 'package:flutter_test/flutter_test.dart';
import 'package:paperlight/tts/narration.dart';

void main() {
  group('pdfParagraphs', () {
    test('rejoins hard-wrapped lines and hyphenated words', () {
      const raw = 'It was a bright cold day in April, and the clocks were\n'
          'striking thirteen. Winston Smith, his chin nuzzled into his\n'
          'breast in an effort to escape the vile wind, slipped quick-\n'
          'ly through the glass doors of Victory Mansions.\n'
          '\n'
          'The hallway smelt of boiled cabbage and old rag mats. At\n'
          'one end of it a coloured poster had been tacked to the wall.';
      final p = pdfParagraphs(raw);
      expect(p, hasLength(2));
      expect(p[0], contains('clocks were striking thirteen'));
      expect(p[0], contains('slipped quickly through'));
      expect(p[1], startsWith('The hallway smelt'));
    });

    test('a short line ending a sentence closes the paragraph', () {
      const raw = 'This is a long line of ordinary prose that fills the width\n'
          'of the page from one margin right across to the other one.\n'
          'And it ends here.\n'
          'A new paragraph begins on this line and runs on for a while\n'
          'until it too reaches its own natural conclusion at the end.';
      final p = pdfParagraphs(raw);
      expect(p, hasLength(2));
      expect(p[0], endsWith('And it ends here.'));
      expect(p[1], startsWith('A new paragraph'));
    });

    test('drops page numbers and running headers', () {
      const page = 'THE GREAT GATSBY\n'
          'In my younger and more vulnerable years my father gave me\n'
          'some advice that I have been turning over in my mind ever since.\n'
          '12';
      const prev = 'THE GREAT GATSBY\nSomething else on the page before.\n11';
      final p = pdfParagraphs(page, neighbours: [prev]);
      expect(p.join(' '), isNot(contains('GATSBY')));
      expect(p.join(' '), isNot(contains('12')));
      expect(p.single, startsWith('In my younger'));
    });

    test('keeps headings as their own paragraph', () {
      const raw = 'Chapter 3\n'
          'There was music from my neighbour\'s house through the summer\n'
          'nights. In his blue gardens men and girls came and went.';
      final p = pdfParagraphs(raw);
      expect(p.first, 'Chapter 3');
      expect(p, hasLength(2));
    });
  });

  group('splitSentences', () {
    test('does not split on abbreviations, initials or decimals', () {
      final s = splitSentences(
          'Mr. Smith met Dr. Jones at 3.5 miles out. J. R. R. Tolkien wrote it, '
          'e.g. The Hobbit. "Really?" she asked. Yes.');
      expect(s, [
        'Mr. Smith met Dr. Jones at 3.5 miles out.',
        'J. R. R. Tolkien wrote it, e.g. The Hobbit.',
        '"Really?" she asked.',
        'Yes.',
      ]);
    });

    test('keeps a closing quote with its sentence', () {
      final s = splitSentences('"Go home." He went.');
      expect(s, ['"Go home."', 'He went.']);
    });
  });

  group('normalise', () {
    test('plain quotes, spoken dashes, no footnote numbers', () {
      expect(normalise('“Well”—she said—‘no.’'),
          '"Well", she said, \'no.\'');
      expect(normalise('as shown before.12 Then'), 'as shown before. Then');
      expect(normalise('a claim[3] here'), 'a claim here');
      expect(normalise('Wait…'), 'Wait...');
    });

    test('leaves real numbers alone', () {
      expect(normalise('In 1984 there were 12 of them.'),
          'In 1984 there were 12 of them.');
    });
  });

  group('buildUtterances', () {
    test('groups short sentences, pauses longer at paragraph ends', () {
      final u = buildUtterances([
        'One. Two. Three.',
        'A second paragraph.',
      ]);
      expect(u, hasLength(2));
      expect(u[0].text, 'One. Two. Three.');
      expect(u[0].pauseAfter, paragraphPause);
      expect(u[1].text, 'A second paragraph.');
    });

    test('splits at the chunk size between sentences', () {
      final long = List.filled(10, 'This sentence is about forty chars long.').join(' ');
      final u = buildUtterances([long], maxChunk: 100);
      expect(u.length, greaterThan(3));
      for (final x in u) {
        expect(x.text.length, lessThanOrEqualTo(100));
      }
      expect(u.last.pauseAfter, paragraphPause);
      expect(u.first.pauseAfter, sentencePause);
    });

    test('headings get a long pause, and so does the text before them', () {
      final u = buildUtterances(['The end of a part.', 'Chapter 2', 'It began.']);
      expect(u[0].pauseAfter, headingPause);
      expect(u[1].heading, isTrue);
      expect(u[1].pauseAfter, headingPause);
    });

    test('very long sentences are split at a natural break', () {
      final s = '${List.filled(20, 'word').join(' ')}, ${List.filled(30, 'more').join(' ')}.';
      final u = buildUtterances([s], maxChunk: 120);
      expect(u.length, greaterThan(1));
      expect(u.first.text, endsWith(','));
    });
  });

  group('narratePage', () {
    test('a sentence split across pages is spoken in one piece', () {
      final p1 = narratePage(
          'He opened the door. Outside, the rain had\n', pdf: false);
      expect(p1.carry, 'Outside, the rain had');
      expect(p1.utterances.single.text, 'He opened the door.');

      final p2 = narratePage('finally stopped. The street was quiet.',
          pdf: false, carry: p1.carry);
      expect(p2.utterances.single.text,
          'Outside, the rain had finally stopped. The street was quiet.');
      expect(p2.carry, isEmpty);
    });

    test('a word hyphenated across pages is rejoined', () {
      final p1 = narratePage('It was a won-', pdf: true);
      expect(p1.carry, 'It was a won-');
      final p2 = narratePage('derful day.', pdf: true, carry: p1.carry);
      expect(p2.utterances.single.text, 'It was a wonderful day.');
    });

    test('a heading at the bottom of a page is not carried', () {
      final p = narratePage('The end.\n\nChapter 4', pdf: false);
      expect(p.carry, isEmpty);
      expect(p.utterances.last.text, 'Chapter 4');
    });

    test('an empty page passes the carry through', () {
      final p = narratePage('', pdf: true, carry: 'and so');
      expect(p.carry, 'and so');
      expect(p.utterances, isEmpty);
    });
  });
}
