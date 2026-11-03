import 'package:flutter/material.dart';

import '../../app/prefs.dart';
import '../../app/theme.dart';
import '../../data/models.dart';

/// "Notes & marks": bookmarks plus highlights, underlines, notes and ink.
Future<void> showMarksSheet(
  BuildContext context, {
  required Future<List<Bookmark>> Function() loadBookmarks,
  required void Function(Bookmark) onOpenBookmark,
  required Future<void> Function(Bookmark) onDeleteBookmark,
  required Future<List<Annotation>> Function() loadAnnotations,
  required void Function(Annotation) onOpenAnnotation,
  required Future<void> Function(Annotation) onDeleteAnnotation,
  required bool isPdf,
  int initialTab = 0,
}) {
  final h = MediaQuery.sizeOf(context).height;
  return showModalBottomSheet(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (c) => SizedBox(
      height: h * 0.72,
      child: DefaultTabController(
        length: 2,
        initialIndex: initialTab,
        child: Column(children: [
          const TabBar(
            labelStyle: TextStyle(fontSize: 17, fontWeight: FontWeight.w700),
            unselectedLabelStyle: TextStyle(fontSize: 17),
            tabs: [
              Tab(text: 'Highlights & notes'),
              Tab(text: 'Bookmarks'),
            ],
          ),
          Expanded(
            child: TabBarView(children: [
              _AnnotationList(
                  load: loadAnnotations,
                  onOpen: onOpenAnnotation,
                  onDelete: onDeleteAnnotation,
                  isPdf: isPdf),
              _BookmarkList(
                  load: loadBookmarks,
                  onOpen: onOpenBookmark,
                  onDelete: onDeleteBookmark),
            ]),
          ),
        ]),
      ),
    ),
  );
}

class _Empty extends StatelessWidget {
  const _Empty(this.text);
  final String text;
  @override
  Widget build(BuildContext context) => Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Text(text,
              textAlign: TextAlign.center, style: const TextStyle(fontSize: 17)),
        ),
      );
}

class _BookmarkList extends StatefulWidget {
  const _BookmarkList(
      {required this.load, required this.onOpen, required this.onDelete});
  final Future<List<Bookmark>> Function() load;
  final void Function(Bookmark) onOpen;
  final Future<void> Function(Bookmark) onDelete;

  @override
  State<_BookmarkList> createState() => _BookmarkListState();
}

class _BookmarkListState extends State<_BookmarkList> {
  List<Bookmark>? _items;

  @override
  void initState() {
    super.initState();
    widget.load().then((v) => mounted ? setState(() => _items = v) : null);
  }

  @override
  Widget build(BuildContext context) {
    final items = _items;
    if (items == null) return const Center(child: CircularProgressIndicator());
    if (items.isEmpty) {
      return const _Empty('No bookmarks yet.\n\nTap the middle of the page, then the '
          'bookmark button at the top to save your place.');
    }
    return ListView(children: [
      for (final b in items)
        _Removable(
          key: ValueKey('b${b.id}'),
          onRemove: () async {
            await widget.onDelete(b);
            setState(() => items.remove(b));
          },
          child: ListTile(
            contentPadding: const EdgeInsets.symmetric(horizontal: 24),
            minVerticalPadding: 14,
            leading: const Icon(Icons.bookmark_rounded),
            title: Text(b.label, style: const TextStyle(fontSize: 17)),
            subtitle: Text('${(b.progress * 100).round()}% · swipe left to remove'),
            onTap: () {
              Navigator.pop(context);
              widget.onOpen(b);
            },
          ),
        ),
    ]);
  }
}

class _AnnotationList extends StatefulWidget {
  const _AnnotationList(
      {required this.load,
      required this.onOpen,
      required this.onDelete,
      required this.isPdf});
  final Future<List<Annotation>> Function() load;
  final void Function(Annotation) onOpen;
  final Future<void> Function(Annotation) onDelete;
  final bool isPdf;

  @override
  State<_AnnotationList> createState() => _AnnotationListState();
}

class _AnnotationListState extends State<_AnnotationList> {
  List<Annotation>? _items;

  @override
  void initState() {
    super.initState();
    widget.load().then((v) => mounted ? setState(() => _items = v) : null);
  }

  String _title(Annotation a) {
    if (widget.isPdf) {
      final what = switch (a.kind) {
        AnnotationKind.ink => 'Drawing',
        _ => 'Note',
      };
      return 'Page ${a.location} · $what';
    }
    final ex = (a.excerpt ?? '').replaceAll(RegExp(r'\s+'), ' ').trim();
    return ex.isEmpty ? 'Highlight' : '“${ex.length > 140 ? '${ex.substring(0, 140)}…' : ex}”';
  }

  Widget _leading(Annotation a) {
    final c = a.color == null ? null : Color(a.color!);
    return switch (a.kind) {
      AnnotationKind.underline => Icon(Icons.format_underlined_rounded, color: c),
      AnnotationKind.ink => Icon(Icons.draw_rounded, color: c),
      AnnotationKind.note => const Icon(Icons.sticky_note_2_outlined),
      AnnotationKind.highlight => Container(
          width: 22,
          height: 22,
          decoration: BoxDecoration(
              color: c ?? Colors.yellow,
              borderRadius: BorderRadius.circular(6),
              border: Border.all(color: Colors.black26)),
        ),
    };
  }

  @override
  Widget build(BuildContext context) {
    final items = _items;
    if (items == null) return const Center(child: CircularProgressIndicator());
    if (items.isEmpty) {
      return _Empty(widget.isPdf
          ? 'No drawings or notes yet.\n\nWrite on the page with your S Pen, or tap '
              'the pen button at the top to draw with your finger.'
          : 'No highlights yet.\n\nPress and hold a word, drag to choose more text, '
              'then pick a colour.');
    }
    return ListView(children: [
      for (final a in items)
        _Removable(
          key: ValueKey('a${a.id}'),
          onRemove: () async {
            await widget.onDelete(a);
            setState(() => items.remove(a));
          },
          child: ListTile(
            contentPadding: const EdgeInsets.symmetric(horizontal: 24),
            minVerticalPadding: 14,
            leading: SizedBox(width: 28, child: Center(child: _leading(a))),
            title: Text(_title(a),
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 17)),
            subtitle: Text(
              [
                if (a.hasNote) a.note!.trim(),
                '${(a.progress * 100).round()}% · swipe left to remove',
              ].join('\n'),
              maxLines: 4,
              overflow: TextOverflow.ellipsis,
            ),
            onTap: () {
              Navigator.pop(context);
              widget.onOpen(a);
            },
          ),
        ),
    ]);
  }
}

class _Removable extends StatelessWidget {
  const _Removable({super.key, required this.onRemove, required this.child});
  final Future<void> Function() onRemove;
  final Widget child;
  @override
  Widget build(BuildContext context) => Dismissible(
        key: key!,
        direction: DismissDirection.endToStart,
        background: Container(
          color: Theme.of(context).colorScheme.errorContainer,
          alignment: Alignment.centerRight,
          padding: const EdgeInsets.only(right: 24),
          child: const Icon(Icons.delete_outline_rounded),
        ),
        onDismissed: (_) => onRemove(),
        child: child,
      );
}

/// The "Aa" sheet. [isEpub] controls whether text options are shown —
/// PDFs have fixed layout so only theme / brightness / page mode apply.
Future<void> showDisplaySheet(BuildContext context,
    {required ReaderPrefs prefs, required bool isEpub}) {
  return showModalBottomSheet(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (c) => ListenableBuilder(
      listenable: prefs,
      builder: (c, _) => SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            if (isEpub) ...[
              const _Label('Text size'),
              Row(children: [
                IconButton.filledTonal(
                  tooltip: 'Smaller text',
                  onPressed: prefs.fontStep > 0 ? () => prefs.fontStep-- : null,
                  icon: const Text('A', style: TextStyle(fontSize: 16)),
                ),
                Expanded(
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                    children: [
                      for (var i = 0; i < ReaderPrefs.fontSizes.length; i++)
                        Container(
                          width: 12,
                          height: 12,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: i <= prefs.fontStep
                                ? Theme.of(c).colorScheme.primary
                                : Theme.of(c).colorScheme.outlineVariant,
                          ),
                        ),
                    ],
                  ),
                ),
                IconButton.filledTonal(
                  tooltip: 'Bigger text',
                  onPressed: prefs.fontStep < ReaderPrefs.fontSizes.length - 1
                      ? () => prefs.fontStep++
                      : null,
                  icon: const Text('A', style: TextStyle(fontSize: 28)),
                ),
              ]),
              const _Label('Font'),
              _Choice<ReadingFont>(
                values: ReadingFont.values,
                selected: prefs.font,
                label: (f) => f.label,
                style: (f) => TextStyle(fontFamily: f.flutterFamily, fontSize: 16),
                onSelect: (f) => prefs.font = f,
              ),
              const _Label('Line spacing'),
              _Choice<int>(
                values: const [0, 1, 2],
                selected: prefs.lineStep,
                label: (i) => const ['Tight', 'Normal', 'Wide'][i],
                onSelect: (i) => prefs.lineStep = i,
              ),
              const _Label('Margins'),
              _Choice<int>(
                values: const [0, 1, 2],
                selected: prefs.marginStep,
                label: (i) => const ['Small', 'Medium', 'Large'][i],
                onSelect: (i) => prefs.marginStep = i,
              ),
            ] else ...[
              const _Label('Page turning'),
              _Choice<PdfMode>(
                values: PdfMode.values,
                selected: prefs.pdfMode,
                label: (m) => m == PdfMode.pages ? 'Turn pages' : 'Scroll down',
                onSelect: (m) => prefs.pdfMode = m,
              ),
            ],
            const _Label('Page colour'),
            Row(children: [
              for (final t in PageTheme.values)
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 4),
                    child: _ThemeSwatch(
                      theme: t,
                      selected: prefs.theme == t,
                      onTap: () => prefs.theme = t,
                    ),
                  ),
                ),
            ]),
            const _Label('Brightness'),
            Row(children: [
              const Icon(Icons.brightness_low_rounded),
              Expanded(
                child: Slider(
                  value: prefs.brightness ?? 0.5,
                  min: 0.02,
                  onChanged: prefs.brightness == null
                      ? null
                      : (v) => prefs.brightness = v,
                ),
              ),
              const Icon(Icons.brightness_high_rounded),
            ]),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Use tablet brightness'),
              value: prefs.brightness == null,
              onChanged: (auto) => prefs.brightness = auto ? null : 0.5,
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Keep screen on while reading'),
              subtitle: const Text('Uses more battery'),
              value: prefs.keepScreenOn,
              onChanged: (v) => prefs.keepScreenOn = v,
            ),
          ]),
        ),
      ),
    ),
  );
}

class _Label extends StatelessWidget {
  const _Label(this.text);
  final String text;
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(top: 18, bottom: 8),
        child: Text(text,
            style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
      );
}

class _Choice<T> extends StatelessWidget {
  const _Choice({
    required this.values,
    required this.selected,
    required this.label,
    required this.onSelect,
    this.style,
  });
  final List<T> values;
  final T selected;
  final String Function(T) label;
  final TextStyle Function(T)? style;
  final ValueChanged<T> onSelect;

  @override
  Widget build(BuildContext context) => SizedBox(
        width: double.infinity,
        child: SegmentedButton<T>(
          showSelectedIcon: false,
          style: SegmentedButton.styleFrom(minimumSize: const Size(0, 52)),
          segments: [
            for (final v in values)
              ButtonSegment(value: v, label: Text(label(v), style: style?.call(v))),
          ],
          selected: {selected},
          onSelectionChanged: (s) => onSelect(s.first),
        ),
      );
}

class _ThemeSwatch extends StatelessWidget {
  const _ThemeSwatch(
      {required this.theme, required this.selected, required this.onTap});
  final PageTheme theme;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final primary = Theme.of(context).colorScheme.primary;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(14),
      child: Container(
        height: 64,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: theme.background,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
              color: selected ? primary : Colors.grey.shade400,
              width: selected ? 3 : 1),
        ),
        child: Text(theme.label,
            style: TextStyle(
                color: theme.foreground, fontSize: 16, fontWeight: FontWeight.w600)),
      ),
    );
  }
}
