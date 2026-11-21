# Vendored flutter_epub_viewer 2.2.1 (BSD-3, see LICENSE)

Copied from pub.dev and patched for Paperlight annotations:

- `lib/assets/webpage/dist/epub.js` — Underline mark: invisible hit-area rect (no outline), 2px line whose colour
  comes from the mark's styles (was hard-coded 1px black).
- `lib/assets/webpage/html/epubView.js` — `addHighlight` honours the opacity
  argument; `addUnderLine(cfi, color)` draws a coloured, opaque underline.
- `lib/src/epub_controller.dart` — `addUnderline({cfi, color})`.
- Swipe lock: `EpubDisplaySettings.disableSwipe` (`lib/src/models/epub_display_settings.dart`),
  passed as `disableSwipe` by `lib/src/epub_viewer.dart`. In `epubView.js` it makes the
  `detectSwipe` callback a no-op and blocks horizontal `touchmove` drags, so pages turn
  only with Paperlight's arrow buttons. Taps, long-press and text selection are unaffected.
- Read aloud: `getCurrentPageSpeechText()` in `epubView.js` and
  `EpubController.extractCurrentPageSpeechText()` return the page's text with a line
  break between block elements, without footnote markers.
  `getPageSpeechText(ahead)` / `extractPageSpeechText(ahead)` do the same for a later
  page of the chapter on screen (via the view manager's column mapping), so speech
  for the next page can be prepared before turning.

To upgrade: copy the new release over this folder and re-apply these patches.
