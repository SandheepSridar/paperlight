import 'package:flutter/material.dart';

/// Highlighter colours, shared by EPUB highlights and the PDF marker.
const highlightColors = <Color>[
  Color(0xFFFFD54F), // yellow
  Color(0xFF81C784), // green
  Color(0xFF64B5F6), // blue
  Color(0xFFF48FB1), // pink
];

/// Pen colours for PDF ink.
const penColors = <Color>[
  Color(0xFF1A1A1A), // ink black
  Color(0xFFF42902), // Paperlight red
  Color(0xFF1E63D6), // blue
  Color(0xFF2E7D32), // green
];

/// Underline colour for EPUB (readable on white, sepia and black pages).
const underlineColor = Color(0xFFF42902);

/// Positions [child] just above [anchor] (or below it when there's no room),
/// horizontally centred and kept on screen. [anchor] is in the coordinates
/// of the enclosing Stack.
class AnchoredMenu extends StatelessWidget {
  const AnchoredMenu({super.key, required this.anchor, required this.child});
  final Rect anchor;
  final Widget child;

  @override
  Widget build(BuildContext context) =>
      CustomSingleChildLayout(delegate: _AnchorLayout(anchor), child: child);
}

class _AnchorLayout extends SingleChildLayoutDelegate {
  _AnchorLayout(this.anchor);
  final Rect anchor;

  @override
  BoxConstraints getConstraintsForChild(BoxConstraints c) =>
      BoxConstraints.loose(Size(c.maxWidth - 16, c.maxHeight));

  @override
  Offset getPositionForChild(Size size, Size child) {
    const gap = 12.0;
    final x = (anchor.center.dx - child.width / 2)
        .clamp(8.0, size.width - child.width - 8);
    var y = anchor.top - child.height - gap;
    if (y < 8) y = anchor.bottom + gap;
    y = y.clamp(8.0, size.height - child.height - 8);
    return Offset(x, y);
  }

  @override
  bool shouldRelayout(_AnchorLayout old) => old.anchor != anchor;
}

/// The pop-up menu shown for a text selection or an existing mark.
class MarkMenu extends StatelessWidget {
  const MarkMenu({
    super.key,
    this.onColor,
    this.selectedColor,
    this.onUnderline,
    this.onNote,
    this.noteLabel = 'Note',
    this.onCopy,
    this.onRemove,
  });

  final ValueChanged<Color>? onColor;
  final Color? selectedColor;
  final VoidCallback? onUnderline;
  final VoidCallback? onNote;
  final String noteLabel;
  final VoidCallback? onCopy;
  final VoidCallback? onRemove;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      elevation: 8,
      color: scheme.surfaceContainerHigh,
      borderRadius: BorderRadius.circular(20),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
        child: SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            if (onColor != null) ...[
              for (final c in highlightColors)
                ColorDot(
                  color: c,
                  selected: selectedColor?.toARGB32() == c.toARGB32(),
                  tooltip: 'Highlight',
                  onTap: () => onColor!(c),
                ),
              const SizedBox(width: 4),
            ],
            if (onUnderline != null)
              _MenuAction(
                  icon: Icons.format_underlined_rounded,
                  label: 'Underline',
                  onTap: onUnderline!),
            if (onNote != null)
              _MenuAction(
                  icon: Icons.sticky_note_2_outlined,
                  label: noteLabel,
                  onTap: onNote!),
            if (onCopy != null)
              _MenuAction(
                  icon: Icons.copy_rounded, label: 'Copy', onTap: onCopy!),
            if (onRemove != null)
              _MenuAction(
                  icon: Icons.delete_outline_rounded,
                  label: 'Remove',
                  onTap: onRemove!),
          ]),
        ),
      ),
    );
  }
}

class ColorDot extends StatelessWidget {
  const ColorDot({
    super.key,
    required this.color,
    required this.onTap,
    this.selected = false,
    this.tooltip,
  });
  final Color color;
  final bool selected;
  final VoidCallback onTap;
  final String? tooltip;

  @override
  Widget build(BuildContext context) {
    final ring = Theme.of(context).colorScheme.onSurface;
    final dot = InkResponse(
      onTap: onTap,
      radius: 26,
      child: Padding(
        padding: const EdgeInsets.all(6),
        child: Container(
          width: 36,
          height: 36,
          decoration: BoxDecoration(
            color: color,
            shape: BoxShape.circle,
            border: Border.all(
                color: selected ? ring : Colors.black26, width: selected ? 3 : 1),
          ),
          child: selected
              ? Icon(Icons.check_rounded,
                  size: 20,
                  color: color.computeLuminance() > 0.4
                      ? Colors.black87
                      : Colors.white)
              : null,
        ),
      ),
    );
    return tooltip == null ? dot : Tooltip(message: tooltip, child: dot);
  }
}

class _MenuAction extends StatelessWidget {
  const _MenuAction(
      {required this.icon, required this.label, required this.onTap});
  final IconData icon;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(14),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Icon(icon, size: 26),
            const SizedBox(height: 2),
            Text(label, style: const TextStyle(fontSize: 13)),
          ]),
        ),
      );
}

/// A large, friendly dialog for writing a note. Returns null on cancel,
/// '' when the note was cleared.
Future<String?> showNoteDialog(BuildContext context,
    {String? initial, String? excerpt, String title = 'Note'}) {
  final text = TextEditingController(text: initial ?? '');
  return showDialog<String>(
    context: context,
    builder: (c) => AlertDialog(
      title: Text(title),
      content: SizedBox(
        width: 520,
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          if (excerpt != null && excerpt.trim().isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: Text('“${_short(excerpt)}”',
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                      fontStyle: FontStyle.italic, fontSize: 15)),
            ),
          TextField(
            controller: text,
            autofocus: true,
            minLines: 3,
            maxLines: 8,
            textCapitalization: TextCapitalization.sentences,
            style: const TextStyle(fontSize: 18),
            decoration: const InputDecoration(
              hintText: 'Write your thoughts…',
              border: OutlineInputBorder(),
            ),
          ),
        ]),
      ),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(c), child: const Text('Cancel')),
        FilledButton(
            onPressed: () => Navigator.pop(c, text.text.trim()),
            child: const Text('Save')),
      ],
    ),
  );
}

Future<bool> confirmRemove(BuildContext context, String what) async =>
    await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text('Remove this $what?'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(c, false),
              child: const Text('Keep')),
          FilledButton(
              onPressed: () => Navigator.pop(c, true),
              child: const Text('Remove')),
        ],
      ),
    ) ??
    false;

String _short(String s) {
  final one = s.replaceAll(RegExp(r'\s+'), ' ').trim();
  return one.length > 160 ? '${one.substring(0, 160)}…' : one;
}

String oneLine(String s, [int max = 120]) {
  final one = s.replaceAll(RegExp(r'\s+'), ' ').trim();
  return one.length > max ? '${one.substring(0, max)}…' : one;
}
