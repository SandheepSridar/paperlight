import 'dart:async';
import 'dart:collection';
import 'dart:io';

import 'package:audio_session/audio_session.dart';
import 'package:flutter/foundation.dart';
import 'package:just_audio/just_audio.dart';

import 'narration.dart';
import 'voice_engine.dart';

/// Where the narrator gets its text from: the open PDF or EPUB.
abstract class NarrationSource {
  /// Returned by [pageText] for a page that exists but can't be read until
  /// it is on screen (an EPUB's next chapter).
  static const notYet = '\u0000';

  /// True for PDFs, whose text is hard-wrapped and needs repairing.
  bool get pdf;

  /// Raw text of the page [ahead] pages from the one on screen (0 = on
  /// screen, -1 = the page before). Null when there is no such page (the end
  /// of the book), or [notYet].
  Future<String?> pageText(int ahead);

  /// Turns to the next page. False at the end of the book.
  Future<bool> turnNext();
}

enum ReadAloudState { idle, starting, playing, paused }

class _Item {
  _Item(this.u, {this.turnsBefore = 0});
  final Utterance u;

  /// Pages to turn just as this starts playing, so the screen follows the voice.
  final int turnsBefore;
}

/// Reads the book aloud from the page on screen, like an audiobook.
///
/// Speech is generated a few chunks ahead and queued in one gapless
/// playlist, so the only silences are the pauses the text calls for. Pages
/// turn as the voice reaches them.
class ReadAloudController extends ChangeNotifier {
  ReadAloudController({required this.source, required this.voiceId, required this.speed});

  final NarrationSource source;
  String voiceId;
  double speed;

  /// Short messages for the reader: pages without text, or a problem.
  void Function(String message)? onNotice;

  /// How many generated chunks to keep queued ahead of the voice.
  static const _lookahead = 3;

  ReadAloudState _state = ReadAloudState.idle;
  ReadAloudState get state => _state;
  bool get active => _state != ReadAloudState.idle;

  // Interruptions (calls, other apps) are handled below, so our state always
  // matches what the player is doing.
  final _player = AudioPlayer(handleInterruptions: false);
  final _subs = <StreamSubscription<Object?>>[];
  bool _sessionReady = false;
  bool _pausedByInterruption = false;
  bool _warnedEmpty = false;

  int _gen = 0;

  /// Text waiting to be spoken, in order.
  final _queue = Queue<_Item>();

  /// What is in the player's playlist, by index, and its files.
  final _playlist = <_Item>[];
  final _files = <String>[];
  int _handled = -1; // last playlist index whose page turns were done

  /// The unfinished sentence at the bottom of the last page loaded.
  String _carry = '';

  /// Page turns queued in the playlist but not yet done.
  int _pendingTurns = 0;

  /// True once the end of the book has been loaded.
  bool _noMorePages = false;

  /// Serialises page reads and turns, so a read never sees a half-turned page.
  Future<void> _lock = Future.value();
  Future<T> _locked<T>(Future<T> Function() f) {
    final r = _lock.then((_) => f());
    _lock = r.then((_) {}, onError: (_) {});
    return r;
  }

  /// Wakes the generator when playback moves on.
  Completer<void>? _advanced;

  void _set(ReadAloudState s) {
    if (_state == s) return;
    _state = s;
    notifyListeners();
  }

  Future<void> _ensureSession() async {
    if (_sessionReady) return;
    _sessionReady = true;
    final session = await AudioSession.instance;
    await session.configure(const AudioSessionConfiguration.speech());
    // Headphones unplugged: pause rather than read out loud to the room.
    _subs.add(session.becomingNoisyEventStream.listen((_) => pause()));
    // A phone call or another app's audio: pause, and carry on afterwards
    // if the interruption was only temporary.
    _subs.add(session.interruptionEventStream.listen((e) {
      if (e.begin) {
        if (e.type == AudioInterruptionType.duck) return;
        if (_state == ReadAloudState.playing || _state == ReadAloudState.starting) {
          _pausedByInterruption = true;
          pause();
        }
      } else {
        if (_pausedByInterruption && e.type == AudioInterruptionType.pause) resume();
        _pausedByInterruption = false;
      }
    }));
    _subs.add(_player.currentIndexStream.listen(_onIndex));
    _subs.add(_player.processingStateStream.listen((s) {
      if (s == ProcessingState.completed) _wake();
    }));
  }

  void _wake() {
    final a = _advanced;
    if (a != null && !a.isCompleted) a.complete();
  }

  // ---------------------------------------------------------------- control

  /// Reads from the top of the page on screen, or from the sentence
  /// containing character [fromOffset] of that page's text.
  Future<void> start({int? fromOffset}) async {
    final g = await _reset();
    _carry = '';
    _pendingTurns = 0;
    _noMorePages = false;
    if (!await _boot(g)) return;
    try {
      final loaded = await _locked(() => _loadPage(0, fromOffset: fromOffset));
      if (g != _gen) return;
      if (!loaded) {
        onNotice?.call('There is no text to read on this page.');
        await stop();
        return;
      }
      // Speak the first sentence on its own, so the voice begins quickly.
      if (_queue.isNotEmpty) {
        final first = _queue.removeFirst();
        final s = splitSentences(first.u.text);
        if (s.length > 1) {
          _queue.addFirst(_Item(Utterance(s.skip(1).join(' '), first.u.pauseAfter)));
          _queue.addFirst(_Item(Utterance(s.first, sentencePause), turnsBefore: first.turnsBefore));
        } else {
          _queue.addFirst(first);
        }
      }
    } catch (e) {
      return _fail(g, e);
    }
    unawaited(_produce(g));
  }

  /// Voice or speed changed: carry on from the sentence being spoken.
  void updateVoice({String? voice, double? newSpeed}) {
    if (voice != null) voiceId = voice;
    if (newSpeed != null) speed = newSpeed;
    if (active) _restartHere();
  }

  Future<void> _restartHere() async {
    final i = _player.currentIndex ?? 0;
    final keep = <_Item>[
      if (i < _playlist.length) _Item(_playlist[i].u), // its page is already showing
      for (var j = i + 1; j < _playlist.length; j++) _playlist[j],
      ..._queue,
    ];
    final wasPaused = _state == ReadAloudState.paused;
    final g = await _reset();
    _queue.addAll(keep);
    if (wasPaused) _set(ReadAloudState.paused);
    if (!await _boot(g)) return;
    unawaited(_produce(g));
  }

  /// The reader turned the page by hand: carry on from the new page.
  void restartIfActive() {
    if (active) start();
  }

  Future<void> pause() async {
    if (_state != ReadAloudState.playing && _state != ReadAloudState.starting) return;
    _set(ReadAloudState.paused);
    await _player.pause();
  }

  Future<void> resume() async {
    if (_state != ReadAloudState.paused) return;
    _pausedByInterruption = false;
    await (await AudioSession.instance).setActive(true);
    final started = _playlist.isNotEmpty;
    _set(started ? ReadAloudState.playing : ReadAloudState.starting);
    if (started) {
      await _resumeIfStalled();
      unawaited(_player.play());
    }
  }

  Future<void> stop() async {
    _gen++;
    _queue.clear();
    _wake();
    _set(ReadAloudState.idle);
    await _player.stop();
    _clearPlaylist();
  }

  /// Stops everything in flight and returns the new generation number.
  Future<int> _reset() async {
    final g = ++_gen;
    _queue.clear();
    _wake();
    await _player.stop();
    if (g != _gen) return g;
    _clearPlaylist();
    _set(ReadAloudState.starting);
    return g;
  }

  void _clearPlaylist() {
    for (final f in _files) {
      if (f.isNotEmpty) File(f).delete().ignore();
    }
    _files.clear();
    _playlist.clear();
    _handled = -1;
  }

  Future<bool> _boot(int g) async {
    try {
      await _ensureSession();
      await VoiceEngine.instance.start(voiceById(voiceId).accent);
      return g == _gen;
    } catch (e) {
      if (g != _gen) return false;
      onNotice?.call("The voice couldn't start. Try removing it in Settings and downloading it again.");
      _set(ReadAloudState.idle);
      return false;
    }
  }

  Future<void> _fail(int g, Object e) async {
    if (g != _gen) return;
    debugPrint('Read aloud failed: $e');
    final why = '$e'.replaceAll('Exception: ', '');
    onNotice?.call('Reading aloud stopped because of a problem ($why).');
    await stop();
  }

  // ---------------------------------------------------------------- pages

  /// Queues the utterances of the page [ahead] pages from the screen
  /// (skipping pages without text). Returns false when there is nothing
  /// more to read now: the end of the book, or (for [NarrationSource.notYet])
  /// a page that must be turned to first.
  Future<bool> _loadPage(int ahead, {int? fromOffset}) async {
    var empty = 0;
    while (true) {
      var raw = await source.pageText(ahead);
      if (raw == null) {
        _noMorePages = true;
        return false;
      }
      if (raw == NarrationSource.notYet) return false;
      if (fromOffset != null) {
        raw = raw.substring(sentenceStartBefore(raw, fromOffset));
        fromOffset = null;
      }
      final neighbours = <String>[];
      if (source.pdf) {
        for (final d in [-1, 1]) {
          final n = await source.pageText(ahead + d);
          if (n != null && n != NarrationSource.notYet) neighbours.add(n);
        }
      }
      final page = narratePage(raw, pdf: source.pdf, carry: _carry, neighbours: neighbours);
      _carry = page.carry;
      if (page.utterances.isNotEmpty) {
        var first = true;
        for (final u in page.utterances) {
          _queue.add(_Item(u, turnsBefore: first ? ahead - _pendingTurns : 0));
          first = false;
        }
        _pendingTurns = ahead;
        return true;
      }
      // A page with no text (a picture, a blank page): skip it.
      if (raw.trim().isEmpty && !_warnedEmpty) {
        _warnedEmpty = true;
        onNotice?.call('Skipping a page with no readable text.');
      }
      if (++empty >= 5) {
        onNotice?.call("These pages have no readable text (they may be scanned images), so they can't be read aloud.");
        _noMorePages = true;
        return false;
      }
      ahead++;
    }
  }

  // ---------------------------------------------------------------- playback

  /// Generates speech ahead of the voice and feeds the playlist.
  Future<void> _produce(int g) async {
    bool alive() => g == _gen;
    var failures = 0;
    try {
      while (alive()) {
        // Enough queued ahead: wait for the voice to move on.
        final playing = _player.currentIndex ?? 0;
        if (_playlist.length - playing > _lookahead) {
          await (_advanced = Completer<void>()).future;
          continue;
        }

        if (_queue.isEmpty && !_noMorePages) {
          final more = await _locked(() => _loadPage(1 + _pendingTurns));
          if (!alive()) return;
          if (!more && !_noMorePages) {
            // The next page can only be read once it is on screen: let the
            // voice finish this page, turn, and read on.
            await _waitUntilPlayed();
            if (!alive()) return;
            final turned = await _locked(() async {
              if (!await source.turnNext()) return false;
              _pendingTurns = 0;
              return _loadPage(0);
            });
            if (!alive()) return;
            if (!turned && _queue.isEmpty) _noMorePages = true;
          }
          continue;
        }
        if (_queue.isEmpty) {
          // End of the book: stop once the last words have been spoken.
          await _waitUntilPlayed();
          if (alive()) await stop();
          return;
        }

        final item = _queue.removeFirst();
        final Clip clip;
        try {
          clip = await VoiceEngine.instance.synthesize(item.u.text,
              voice: voiceById(voiceId), speed: speed, pauseAfter: item.u.pauseAfter);
          failures = 0;
        } catch (e) {
          if (!alive()) return;
          debugPrint('Read aloud: skipped "${item.u.text}": $e');
          if (++failures >= 3) rethrow;
          // Keep any page turn this chunk carried.
          if (item.turnsBefore > 0 && _queue.isNotEmpty) {
            final next = _queue.removeFirst();
            _queue.addFirst(_Item(next.u, turnsBefore: next.turnsBefore + item.turnsBefore));
          }
          continue;
        }
        if (!alive()) {
          File(clip.path).delete().ignore();
          return;
        }
        await _append(item, clip);
      }
    } catch (e) {
      await _fail(g, e);
    }
  }

  Future<void> _append(_Item item, Clip clip) async {
    _playlist.add(item);
    _files.add(clip.path);
    final audio = AudioSource.file(clip.path);
    if (_playlist.length == 1) {
      await _player.setAudioSources([audio]);
      if (_state == ReadAloudState.starting) _set(ReadAloudState.playing);
      if (_state == ReadAloudState.playing) unawaited(_player.play());
      return;
    }
    await _player.addAudioSource(audio);
    await _resumeIfStalled();
  }

  /// If the voice caught up with the generator, the player has finished its
  /// playlist: move it on to the newly added chunk.
  Future<void> _resumeIfStalled() async {
    if (_player.processingState != ProcessingState.completed) return;
    final next = (_player.currentIndex ?? 0) + 1;
    if (next >= _playlist.length) return;
    await _player.seek(Duration.zero, index: next);
    if (_state == ReadAloudState.playing) unawaited(_player.play());
  }

  /// Waits until everything in the playlist has been spoken.
  Future<void> _waitUntilPlayed() async {
    final g = _gen;
    while (_playlist.isNotEmpty && g == _gen) {
      final last = _player.currentIndex == _playlist.length - 1;
      if (last && _player.processingState == ProcessingState.completed) return;
      await (_advanced = Completer<void>()).future;
    }
  }

  /// A new chunk started playing: turn pages it begins on, tidy old files.
  void _onIndex(int? index) {
    _wake();
    if (index == null || index <= _handled || index >= _playlist.length) return;
    final g = _gen;
    var turns = 0;
    for (var i = _handled + 1; i <= index; i++) {
      turns += _playlist[i].turnsBefore;
    }
    _handled = index;
    if (turns > 0) {
      _locked(() async {
        for (var t = 0; t < turns && g == _gen; t++) {
          await source.turnNext();
          _pendingTurns = (_pendingTurns - 1).clamp(0, 1 << 20);
        }
      });
    }
    // Clips already played are no longer needed.
    for (var i = 0; i < index - 1; i++) {
      final f = _files[i];
      if (f.isNotEmpty) {
        File(f).delete().ignore();
        _files[i] = '';
      }
    }
  }

  @override
  void dispose() {
    _gen++;
    _wake();
    for (final s in _subs) {
      s.cancel();
    }
    _player.dispose();
    _clearPlaylist();
    super.dispose();
  }
}
