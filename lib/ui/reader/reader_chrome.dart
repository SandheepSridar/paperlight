import 'package:flutter/material.dart';

import '../../app/theme.dart';

/// Kindle-style controls that slide in over the page when the reader taps
/// the middle of the screen. Hidden by default so nothing distracts.
class ReaderChrome extends StatelessWidget {
  const ReaderChrome({
    super.key,
    required this.visible,
    required this.theme,
    required this.title,
    required this.progress,
    required this.progressLabel,
    required this.bookmarked,
    required this.onBack,
    required this.onContents,
    required this.onBookmarks,
    required this.onToggleBookmark,
    required this.onSettings,
    required this.onSeek,
    required this.child,
    this.seekDivisions,
    this.seekLabel,
  });

  final bool visible;
  final PageTheme theme;
  final String title;
  final double progress;
  final String progressLabel;
  final bool bookmarked;
  final VoidCallback onBack;
  final VoidCallback onContents;
  final VoidCallback onBookmarks;
  final VoidCallback onToggleBookmark;
  final VoidCallback onSettings;
  final ValueChanged<double> onSeek;
  final int? seekDivisions;
  final String Function(double)? seekLabel;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final bar = theme == PageTheme.dark
        ? const Color(0xF21C1C1C)
        : theme == PageTheme.sepia
            ? const Color(0xF2EADDC5)
            : const Color(0xF2F4F1EC);
    final fg = theme.foreground;
    const dur = Duration(milliseconds: 180);

    return Stack(children: [
      Positioned.fill(child: child),
      // Small, always-visible progress hint at the bottom like Kindle.
      Positioned(
        left: 0,
        right: 0,
        bottom: 6,
        child: IgnorePointer(
          child: AnimatedOpacity(
            opacity: visible ? 0 : 0.55,
            duration: dur,
            child: Text(progressLabel,
                textAlign: TextAlign.center,
                style: TextStyle(color: fg, fontSize: 13)),
          ),
        ),
      ),
      AnimatedPositioned(
        duration: dur,
        curve: Curves.easeOut,
        top: visible ? 0 : -120,
        left: 0,
        right: 0,
        child: Material(
          color: bar,
          elevation: 2,
          child: SafeArea(
            bottom: false,
            child: IconTheme(
              data: IconThemeData(color: fg),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
                child: Row(children: [
                  IconButton(
                      tooltip: 'Back to library',
                      icon: const Icon(Icons.arrow_back_rounded),
                      onPressed: onBack),
                  Expanded(
                    child: Text(title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                            color: fg, fontSize: 18, fontWeight: FontWeight.w600)),
                  ),
                  IconButton(
                      tooltip: 'Contents',
                      icon: const Icon(Icons.toc_rounded),
                      onPressed: onContents),
                  IconButton(
                      tooltip: 'Bookmarks',
                      icon: const Icon(Icons.bookmarks_outlined),
                      onPressed: onBookmarks),
                  IconButton(
                      tooltip: bookmarked ? 'Remove bookmark' : 'Bookmark this page',
                      icon: Icon(bookmarked
                          ? Icons.bookmark_rounded
                          : Icons.bookmark_add_outlined),
                      onPressed: onToggleBookmark),
                  IconButton(
                      tooltip: 'Text & display',
                      icon: const Icon(Icons.text_fields_rounded),
                      onPressed: onSettings),
                ]),
              ),
            ),
          ),
        ),
      ),
      AnimatedPositioned(
        duration: dur,
        curve: Curves.easeOut,
        bottom: visible ? 0 : -140,
        left: 0,
        right: 0,
        child: Material(
          color: bar,
          elevation: 2,
          child: SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                _SeekSlider(
                  value: progress,
                  divisions: seekDivisions,
                  label: seekLabel,
                  onSeek: onSeek,
                ),
                Text(progressLabel, style: TextStyle(color: fg, fontSize: 15)),
              ]),
            ),
          ),
        ),
      ),
    ]);
  }
}

/// Slider that only jumps when the finger is lifted, so dragging is smooth.
class _SeekSlider extends StatefulWidget {
  const _SeekSlider(
      {required this.value, required this.onSeek, this.divisions, this.label});
  final double value;
  final int? divisions;
  final String Function(double)? label;
  final ValueChanged<double> onSeek;

  @override
  State<_SeekSlider> createState() => _SeekSliderState();
}

class _SeekSliderState extends State<_SeekSlider> {
  double? _drag;

  @override
  Widget build(BuildContext context) {
    final v = (_drag ?? widget.value).clamp(0.0, 1.0);
    return Slider(
      value: v,
      divisions: widget.divisions,
      label: widget.label?.call(v),
      onChanged: (x) => setState(() => _drag = x),
      onChangeEnd: (x) {
        setState(() => _drag = null);
        widget.onSeek(x);
      },
    );
  }
}

class TocEntry {
  TocEntry(this.title, this.depth, this.onTap);
  final String title;
  final int depth;
  final VoidCallback onTap;
}

Future<void> showContentsSheet(BuildContext context, List<TocEntry> entries) {
  return showModalBottomSheet(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (c) => DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.7,
      maxChildSize: 0.95,
      builder: (c, scroll) => entries.isEmpty
          ? const Center(
              child: Padding(
              padding: EdgeInsets.all(32),
              child: Text("This book doesn't have a table of contents.",
                  textAlign: TextAlign.center, style: TextStyle(fontSize: 17)),
            ))
          : ListView.builder(
              controller: scroll,
              itemCount: entries.length + 1,
              itemBuilder: (c, i) {
                if (i == 0) {
                  return const Padding(
                    padding: EdgeInsets.fromLTRB(24, 0, 24, 8),
                    child: Text('Contents',
                        style: TextStyle(fontSize: 22, fontWeight: FontWeight.w700)),
                  );
                }
                final e = entries[i - 1];
                return ListTile(
                  contentPadding:
                      EdgeInsets.only(left: 24.0 + e.depth * 20, right: 24),
                  minVerticalPadding: 14,
                  title: Text(e.title, style: const TextStyle(fontSize: 17)),
                  onTap: () {
                    Navigator.pop(c);
                    e.onTap();
                  },
                );
              },
            ),
    ),
  );
}
