# Vendored flutter_epub_viewer 2.2.1 (BSD-3, see LICENSE)

Copied from pub.dev and patched for Paperlight annotations:

- `lib/assets/webpage/dist/epub.js` — Underline mark: invisible hit-area rect (no outline), 2px line whose colour
  comes from the mark's styles (was hard-coded 1px black).
- `lib/assets/webpage/html/epubView.js` — `addHighlight` honours the opacity
  argument; `addUnderLine(cfi, color)` draws a coloured, opaque underline.
- `lib/src/epub_controller.dart` — `addUnderline({cfi, color})`.

To upgrade: copy the new release over this folder and re-apply these patches.
