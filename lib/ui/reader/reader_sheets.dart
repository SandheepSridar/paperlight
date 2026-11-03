import 'package:flutter/material.dart';

import '../../app/prefs.dart';
import '../../app/theme.dart';
import '../../data/models.dart';

Future<void> showBookmarksSheet(
  BuildContext context, {
  required Future<List<Bookmark>> Function() load,
  required void Function(Bookmark) onOpen,
  required Future<void> Function(Bookmark) onDelete,
}) {
  return showModalBottomSheet(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (c) => DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.6,
      maxChildSize: 0.95,
      builder: (c, scroll) => _BookmarkList(
          scroll: scroll, load: load, onOpen: onOpen, onDelete: onDelete),
    ),
  );
}

class _BookmarkList extends StatefulWidget {
  const _BookmarkList(
      {required this.scroll,
      required this.load,
      required this.onOpen,
      required this.onDelete});
  final ScrollController scroll;
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
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(32),
          child: Text(
            'No bookmarks yet.\n\nTap the middle of the page, then the bookmark '
            'button at the top to save your place.',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 17),
          ),
        ),
      );
    }
    return ListView(controller: widget.scroll, children: [
      const Padding(
        padding: EdgeInsets.fromLTRB(24, 0, 24, 8),
        child: Text('Bookmarks',
            style: TextStyle(fontSize: 22, fontWeight: FontWeight.w700)),
      ),
      for (final b in items)
        Dismissible(
          key: ValueKey(b.id),
          direction: DismissDirection.endToStart,
          background: Container(
            color: Theme.of(context).colorScheme.errorContainer,
            alignment: Alignment.centerRight,
            padding: const EdgeInsets.only(right: 24),
            child: const Icon(Icons.delete_outline_rounded),
          ),
          onDismissed: (_) async {
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
