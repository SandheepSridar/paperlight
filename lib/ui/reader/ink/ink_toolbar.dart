import 'package:flutter/material.dart';

import '../annotation_menus.dart';
import 'ink_controller.dart';

/// Floating tools shown while drawing with a finger: pen / highlighter /
/// eraser, colours, undo, a page note, page turning and Done.
class InkToolbar extends StatelessWidget {
  const InkToolbar({
    super.key,
    required this.controller,
    required this.page,
    required this.pageCount,
    required this.onPrev,
    required this.onNext,
    required this.onNote,
    required this.onDone,
  });

  final InkController controller;
  final int page;
  final int pageCount;
  final VoidCallback onPrev;
  final VoidCallback onNext;
  final VoidCallback onNote;
  final VoidCallback onDone;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        final c = controller;
        final colors = c.tool == DrawTool.marker ? highlightColors : penColors;
        final current = c.tool == DrawTool.marker ? c.markerColor : c.penColor;
        final hasNote = c.notes[page] != null;
        return Material(
          elevation: 10,
          color: scheme.surfaceContainerHigh,
          borderRadius: BorderRadius.circular(28),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
            // Wraps onto two rows on narrow screens (tablet held upright).
            child: Wrap(
              alignment: WrapAlignment.center,
              crossAxisAlignment: WrapCrossAlignment.center,
              runSpacing: 4,
              children: [
                _Tool(
                    icon: Icons.edit_rounded,
                    label: 'Pen',
                    selected: c.tool == DrawTool.pen,
                    onTap: () => c.setTool(DrawTool.pen)),
                _Tool(
                    icon: Icons.border_color_rounded,
                    label: 'Highlight',
                    selected: c.tool == DrawTool.marker,
                    onTap: () => c.setTool(DrawTool.marker)),
                _Tool(
                    icon: Icons.cleaning_services_rounded,
                    label: 'Eraser',
                    selected: c.tool == DrawTool.eraser,
                    onTap: () => c.setTool(DrawTool.eraser)),
                const _Divider(),
                for (final col in colors)
                  ColorDot(
                    color: col,
                    selected: c.tool != DrawTool.eraser &&
                        col.toARGB32() == current.toARGB32(),
                    onTap: () => c.setColor(col),
                  ),
                const _Divider(),
                _Tool(
                    icon: Icons.undo_rounded,
                    label: 'Undo',
                    onTap: c.canUndo ? c.undo : null),
                _Tool(
                    icon: hasNote
                        ? Icons.sticky_note_2_rounded
                        : Icons.sticky_note_2_outlined,
                    label: hasNote ? 'Page note' : 'Add note',
                    onTap: onNote),
                const _Divider(),
                _Tool(
                    icon: Icons.chevron_left_rounded,
                    label: 'Back',
                    onTap: page > 1 ? onPrev : null),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 4),
                  child: Text('$page / $pageCount',
                      style: const TextStyle(fontSize: 15)),
                ),
                _Tool(
                    icon: Icons.chevron_right_rounded,
                    label: 'Next',
                    onTap: page < pageCount ? onNext : null),
                const SizedBox(width: 6),
                FilledButton(onPressed: onDone, child: const Text('Done')),
              ],
            ),
          ),
        );
      },
    );
  }
}

class _Tool extends StatelessWidget {
  const _Tool({
    required this.icon,
    required this.label,
    required this.onTap,
    this.selected = false,
  });
  final IconData icon;
  final String label;
  final VoidCallback? onTap;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final fg = onTap == null
        ? scheme.onSurface.withValues(alpha: 0.35)
        : selected
            ? scheme.onPrimaryContainer
            : scheme.onSurface;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 2),
      child: Material(
        color: selected ? scheme.primaryContainer : Colors.transparent,
        borderRadius: BorderRadius.circular(16),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(16),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              Icon(icon, size: 26, color: fg),
              Text(label, style: TextStyle(fontSize: 12, color: fg)),
            ]),
          ),
        ),
      ),
    );
  }
}

class _Divider extends StatelessWidget {
  const _Divider();
  @override
  Widget build(BuildContext context) => Container(
        width: 1,
        height: 36,
        margin: const EdgeInsets.symmetric(horizontal: 6),
        color: Theme.of(context).colorScheme.outlineVariant,
      );
}
