import 'dart:io';

import 'package:flutter/material.dart';

import '../app/prefs.dart';
import '../data/library_repo.dart';
import '../data/models.dart';
import '../import/importer.dart';
import '../update/updater.dart';
import 'reader/epub_reader.dart';
import 'reader/pdf_reader.dart';
import 'settings_screen.dart';

class LibraryScreen extends StatefulWidget {
  const LibraryScreen(
      {super.key, required this.repo, required this.prefs, required this.updater});
  final LibraryRepo repo;
  final ReaderPrefs prefs;
  final Updater updater;

  @override
  State<LibraryScreen> createState() => _LibraryScreenState();
}

class _LibraryScreenState extends State<LibraryScreen> {
  late final Importer _importer = Importer(widget.repo);
  List<Book>? _books;
  bool _importing = false;

  @override
  void initState() {
    super.initState();
    widget.repo.addListener(_reload);
    _reload();
    WidgetsBinding.instance.addPostFrameCallback(
        (_) => widget.updater.checkOnStartup(context));
  }

  @override
  void dispose() {
    widget.repo.removeListener(_reload);
    super.dispose();
  }

  Future<void> _reload() async {
    final b = await widget.repo.books();
    if (mounted) setState(() => _books = b);
  }

  Future<void> _add() async {
    setState(() => _importing = true);
    try {
      final report = await _importer.pickAndImport();
      if (report != null && mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(report.message)));
      }
    } finally {
      if (mounted) setState(() => _importing = false);
    }
  }

  Future<void> _open(Book book) async {
    final screen = book.format == BookFormat.pdf
        ? PdfReaderScreen(book: book, repo: widget.repo, prefs: widget.prefs)
        : EpubReaderScreen(book: book, repo: widget.repo, prefs: widget.prefs);
    final nav = Navigator.of(context);
    final tip = !widget.prefs.seenReaderTip;
    final route = nav.push(MaterialPageRoute(builder: (_) => screen));
    if (tip) {
      widget.prefs.seenReaderTip = true;
      await Future<void>.delayed(const Duration(milliseconds: 500));
      if (nav.mounted) await showReaderTip(nav.context);
    }
    await route;
    _reload();
  }

  Future<void> _options(Book book) async {
    final action = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (c) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          ListTile(
            title: Text(book.title,
                style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w700)),
            subtitle: Text([
              if (book.author != null) book.author!,
              book.format.name.toUpperCase(),
              '${book.percent}% read',
            ].join(' · ')),
          ),
          const Divider(),
          ListTile(
            leading: const Icon(Icons.menu_book_rounded),
            title: const Text('Open'),
            onTap: () => Navigator.pop(c, 'open'),
          ),
          ListTile(
            leading: Icon(Icons.delete_outline_rounded,
                color: Theme.of(c).colorScheme.error),
            title: Text('Remove from library',
                style: TextStyle(color: Theme.of(c).colorScheme.error)),
            onTap: () => Navigator.pop(c, 'remove'),
          ),
          const SizedBox(height: 8),
        ]),
      ),
    );
    if (!mounted) return;
    if (action == 'open') return _open(book);
    if (action != 'remove') return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Remove this book?'),
        content: Text(
            '"${book.title}" and its bookmarks will be removed from Paperlight. '
            'The original file on your tablet is not affected.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Keep')),
          FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('Remove')),
        ],
      ),
    );
    if (ok == true) await widget.repo.delete(book);
  }

  @override
  Widget build(BuildContext context) {
    final books = _books;
    final recent = books
        ?.where((b) => b.lastOpened != null)
        .fold<Book?>(null, (a, b) => a == null || b.lastOpened!.isAfter(a.lastOpened!) ? b : a);

    return Scaffold(
      appBar: AppBar(
        title: const Text('My Books',
            style: TextStyle(fontSize: 28, fontWeight: FontWeight.w800)),
        toolbarHeight: 72,
        actions: [
          IconButton(
            tooltip: 'Settings',
            icon: const Icon(Icons.settings_outlined),
            onPressed: () => Navigator.push(
                context,
                MaterialPageRoute(
                    builder: (_) =>
                        SettingsScreen(prefs: widget.prefs, updater: widget.updater))),
          ),
          const SizedBox(width: 8),
        ],
      ),
      floatingActionButton: books == null || books.isEmpty
          ? null
          : FloatingActionButton.extended(
              onPressed: _importing ? null : _add,
              icon: const Icon(Icons.add_rounded, size: 28),
              label: const Text('Add book', style: TextStyle(fontSize: 18)),
            ),
      body: Stack(children: [
        if (books == null)
          const Center(child: CircularProgressIndicator())
        else if (books.isEmpty)
          _Empty(onAdd: _add)
        else
          CustomScrollView(slivers: [
            if (recent != null)
              SliverToBoxAdapter(
                child: _ContinueCard(book: recent, onTap: () => _open(recent)),
              ),
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(24, 24, 24, 8),
              sliver: SliverToBoxAdapter(
                child: Text('All books (${books.length})',
                    style: Theme.of(context).textTheme.titleLarge),
              ),
            ),
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(20, 8, 20, 120),
              sliver: SliverGrid.builder(
                gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                  maxCrossAxisExtent: 190,
                  childAspectRatio: 0.56,
                  crossAxisSpacing: 20,
                  mainAxisSpacing: 24,
                ),
                itemCount: books.length,
                itemBuilder: (c, i) => _BookTile(
                  book: books[i],
                  onTap: () => _open(books[i]),
                  onLongPress: () => _options(books[i]),
                ),
              ),
            ),
          ]),
        if (_importing)
          const Positioned.fill(
            child: ColoredBox(
              color: Color(0x66000000),
              child: Center(
                child: Card(
                  child: Padding(
                    padding: EdgeInsets.all(28),
                    child: Column(mainAxisSize: MainAxisSize.min, children: [
                      CircularProgressIndicator(),
                      SizedBox(height: 16),
                      Text('Adding books…', style: TextStyle(fontSize: 18)),
                    ]),
                  ),
                ),
              ),
            ),
          ),
      ]),
    );
  }
}

class _Empty extends StatelessWidget {
  const _Empty({required this.onAdd});
  final VoidCallback onAdd;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Icon(Icons.auto_stories_rounded, size: 96, color: cs.primary),
          const SizedBox(height: 20),
          Text('Your library is empty',
              style: Theme.of(context).textTheme.headlineSmall),
          const SizedBox(height: 12),
          const Text(
            'Add a PDF or EPUB book from your tablet.\n'
            'Only the books you add will show up here.',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 17),
          ),
          const SizedBox(height: 28),
          FilledButton.icon(
            onPressed: onAdd,
            icon: const Icon(Icons.add_rounded),
            label: const Text('Add your first book'),
          ),
        ]),
      ),
    );
  }
}

class _ContinueCard extends StatelessWidget {
  const _ContinueCard({required this.book, required this.onTap});
  final Book book;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 4, 20, 0),
      child: Card(
        elevation: 0,
        color: cs.secondaryContainer,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.all(18),
            child: Row(children: [
              SizedBox(width: 92, height: 136, child: Cover(book: book)),
              const SizedBox(width: 20),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text('CONTINUE READING',
                      style: TextStyle(
                          fontSize: 13,
                          letterSpacing: 1.2,
                          fontWeight: FontWeight.w700,
                          color: cs.onSecondaryContainer.withValues(alpha: 0.7))),
                  const SizedBox(height: 6),
                  Text(book.title,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w700)),
                  if (book.author != null)
                    Text(book.author!,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 16)),
                  const SizedBox(height: 14),
                  ClipRRect(
                    borderRadius: BorderRadius.circular(4),
                    child: LinearProgressIndicator(value: book.progress, minHeight: 6),
                  ),
                  const SizedBox(height: 6),
                  Text('${book.percent}% read', style: const TextStyle(fontSize: 15)),
                ]),
              ),
              // On narrow screens the whole card is the button; on the
              // tablet there's room for an explicit one.
              if (MediaQuery.sizeOf(context).width >= 560) ...[
                const SizedBox(width: 12),
                FilledButton(onPressed: onTap, child: const Text('Continue')),
              ],
            ]),
          ),
        ),
      ),
    );
  }
}

class _BookTile extends StatelessWidget {
  const _BookTile(
      {required this.book, required this.onTap, required this.onLongPress});
  final Book book;
  final VoidCallback onTap;
  final VoidCallback onLongPress;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      onLongPress: onLongPress,
      borderRadius: BorderRadius.circular(10),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Expanded(child: Cover(book: book)),
        const SizedBox(height: 8),
        Text(book.title,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
        const SizedBox(height: 4),
        Row(children: [
          Expanded(
            child: ClipRRect(
              borderRadius: BorderRadius.circular(3),
              child: LinearProgressIndicator(value: book.progress, minHeight: 4),
            ),
          ),
          const SizedBox(width: 8),
          Text(book.progress == 0 ? 'New' : '${book.percent}%',
              style: const TextStyle(fontSize: 13)),
        ]),
      ]),
    );
  }
}

/// Book cover thumbnail, or a tidy title card if the book has none.
class Cover extends StatelessWidget {
  const Cover({super.key, required this.book});
  final Book book;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final path = book.coverPath;
    final fallback = Container(
      color: cs.primaryContainer,
      padding: const EdgeInsets.all(12),
      alignment: Alignment.center,
      child: Text(book.title,
          textAlign: TextAlign.center,
          maxLines: 5,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
              fontFamily: 'serif',
              fontSize: 16,
              fontWeight: FontWeight.w600,
              color: cs.onPrimaryContainer)),
    );
    return DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(8),
        boxShadow: const [
          BoxShadow(color: Color(0x33000000), blurRadius: 6, offset: Offset(0, 3)),
        ],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(8),
        child: SizedBox.expand(
          child: path == null
              ? fallback
              : Image.file(File(path),
                  fit: BoxFit.cover,
                  // Decode at display size: keeps memory and GPU work low.
                  cacheWidth: 400,
                  gaplessPlayback: true,
                  errorBuilder: (_, _, _) => fallback),
        ),
      ),
    );
  }
}

Future<void> showReaderTip(BuildContext context) => showDialog(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('How to read'),
        content: const Column(mainAxisSize: MainAxisSize.min, children: [
          _TipRow(Icons.touch_app_rounded, 'Tap the right side (or swipe left) for the next page.'),
          _TipRow(Icons.undo_rounded, 'Tap the left side to go back a page.'),
          _TipRow(Icons.menu_rounded, 'Tap the middle to show the menu: text size, colours, bookmarks and contents.'),
          _TipRow(Icons.save_rounded, 'Your place is saved automatically.'),
        ]),
        actions: [
          FilledButton(onPressed: () => Navigator.pop(c), child: const Text('Got it')),
        ],
      ),
    );

class _TipRow extends StatelessWidget {
  const _TipRow(this.icon, this.text);
  final IconData icon;
  final String text;
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Icon(icon, size: 28),
          const SizedBox(width: 14),
          Expanded(child: Text(text, style: const TextStyle(fontSize: 17))),
        ]),
      );
}
