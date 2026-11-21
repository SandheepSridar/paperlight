import 'dart:async';
import 'dart:collection';

import 'package:audio_session/audio_session.dart';
import 'package:flutter/foundation.dart';
import 'package:just_audio/just_audio.dart';

import 'narration.dart';
import 'voice_engine.dart';

/// Where the narrator gets its text from: the open PDF or EPUB.
abstract class NarrationSource {
  /// True for PDFs, whose text is hard-wrapped and needs repairing.
  bool get pdf;

  /// True when pages ahead can be read without turning to them (PDF). EPUB
  /// text is only available for the page on screen.
  bool get canPeek;

  /// Raw text of the page [ahead] pages from the one on screen (0 = on
  /// screen, -1 = the page before). Null when there is no such page.
  Future<String?> pageText(int ahead);

  /// Turns to the next page. False at the end of the book.
  Future<bool> turnNext();
}

enum ReadAloudState { idle, starting, playing, paused }

class _Item {
  _Item(this.u, {this.turnsBefore = 0});
  final Utterance u;

  /// Pages to turn just before this is spoken, so the screen follows the voice.
  final int turnsBefore;
}

/// Reads the book aloud from the page on screen, like an audiobook:
/// synthesises one chunk ahead while the current one plays, and turns pages
/// as the voice reaches them.
class ReadAloudController extends ChangeNotifier {
  ReadAloudController({required this.source, required this.voiceId, required this.speed});

  final NarrationSource source;
  String voiceId;
  double speed;

  /// Short messages for the reader: pages without text, or a problem.
  void Function(String message)? onNotice;

  ReadAloudState _state = ReadAloudState.idle;
  ReadAloudState get state => _state;
  bool get active => _state != ReadAloudState.idle;

  // Interruptions (calls, other apps) are handled below, so our state always
  // matches what the player is doing.
  final _player = AudioPlayer(handleInterruptions: false);
  StreamSubscription<PlayerState>? _playerSub;
  StreamSubscription<void>? _noisySub;
  StreamSubscription<AudioInterruptionEvent>? _interruptSub;
  bool _pausedByInterruption = false;
  Completer<void>? _clipDone;
  int _gen = 0;
  bool _sessionReady = false;
  bool _warnedEmpty = false;

  // Pages queued ahead (PDF) and the unfinished sentence between pages.
  final _queue = Queue<_Item>();
  String _carry = '';
  int _peeked = 0; // how many pages after the on-screen one are queued

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
    _noisySub = session.becomingNoisyEventStream.listen((_) => pause());
    // A phone call or another app's audio: pause, and carry on afterwards
    // if the interruption was only temporary.
    _interruptSub = session.interruptionEventStream.listen((e) {
      if (e.begin) {
        if (e.type == AudioInterruptionType.duck) return;
        if (_state == ReadAloudState.playing || _state == ReadAloudState.starting) {
          _pausedByInterruption = true;
          pause();
        }
      } else {
        if (_pausedByInterruption && e.type == AudioInterruptionType.pause) {
          resume();
        }
        _pausedByInterruption = false;
      }
    });
    _playerSub = _player.playerStateStream.listen((s) {
      if (s.processingState == ProcessingState.completed) {
        final c = _clipDone;
        if (c != null && !c.isCompleted) c.complete();
      }
    });
  }

  /// Starts (or restarts) reading from the top of the page on screen.
  Future<void> start() async {
    final g = ++_gen;
    _queue.clear();
    _carry = '';
    _peeked = 0;
    _finishClip();
    await _player.stop();
    _set(ReadAloudState.starting);
    try {
      await _ensureSession();
      await VoiceEngine.instance.start();
    } catch (e) {
      if (g != _gen) return;
      onNotice?.call("The voice couldn't start. Try removing it in Settings and downloading it again.");
      _set(ReadAloudState.idle);
      return;
    }
    if (g != _gen) return;
    unawaited(_run(g));
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
    final session = await AudioSession.instance;
    await session.setActive(true);
    _set(ReadAloudState.playing);
    if (_player.processingState == ProcessingState.ready) {
      unawaited(_player.play());
    }
  }

  Future<void> stop() async {
    _gen++;
    _queue.clear();
    _finishClip();
    _set(ReadAloudState.idle);
    await _player.stop();
  }

  /// Voice or speed changed: re-read from the current chunk's page.
  void updateVoice({String? voice, double? newSpeed}) {
    if (voice != null) voiceId = voice;
    if (newSpeed != null) speed = newSpeed;
    if (active) start();
  }

  void _finishClip() {
    final c = _clipDone;
    if (c != null && !c.isCompleted) c.complete();
  }

  // ---------------------------------------------------------------- loop

  /// Queues the utterances of the page [ahead] pages from the screen.
  /// Returns false at the end of the book.
  Future<bool> _loadPage(int ahead, int turnsBefore) async {
    var turns = turnsBefore;
    var empty = 0;
    while (true) {
      final raw = await source.pageText(ahead);
      if (raw == null) return false;
      final neighbours = <String>[];
      if (source.pdf && source.canPeek) {
        for (final d in [-1, 1]) {
          final n = await source.pageText(ahead + d);
          if (n != null) neighbours.add(n);
        }
      }
      final page = narratePage(raw, pdf: source.pdf, carry: _carry, neighbours: neighbours);
      _carry = page.carry;
      if (page.utterances.isNotEmpty) {
        var first = true;
        for (final u in page.utterances) {
          _queue.add(_Item(u, turnsBefore: first ? turns : 0));
          first = false;
        }
        return true;
      }
      // A page with no text (a picture, a blank page): skip it.
      if (raw.trim().isEmpty && !_warnedEmpty) {
        _warnedEmpty = true;
        onNotice?.call('Skipping a page with no readable text.');
      }
      if (++empty >= 5) {
        onNotice?.call("These pages have no readable text (they may be scanned images), so they can't be read aloud.");
        return false;
      }
      if (source.canPeek) {
        ahead++;
        turns++;
        _peeked++;
      } else {
        if (!await source.turnNext()) return false;
      }
    }
  }

  /// Speaks just the first sentence on its own, so the voice starts
  /// quickly; the rest of the chunk follows straight after.
  _Item _quickFirst(_Item item) {
    final sentences = splitSentences(item.u.text);
    if (sentences.length < 2) return item;
    _queue.addFirst(_Item(Utterance(sentences.skip(1).join(' '), item.u.pauseAfter)));
    return _Item(Utterance(sentences.first, sentencePause), turnsBefore: item.turnsBefore);
  }

  /// Null when this one chunk couldn't be spoken; it is skipped.
  Future<Clip?> _synth(_Item item) => VoiceEngine.instance
      .synthesize(item.u.text,
          sid: voiceById(voiceId).sid, speed: speed, pauseAfter: item.u.pauseAfter)
      .then<Clip?>((c) => c, onError: (Object e) {
    _lastFailure = e;
    debugPrint('Read aloud: skipped "${item.u.text}": $e');
    return null;
  });

  Object? _lastFailure;

  Future<void> _run(int g) async {
    bool alive() => g == _gen;
    try {
      if (!await _loadPage(0, 0)) {
        if (alive()) {
          onNotice?.call('There is no text to read on this page.');
          await stop();
        }
        return;
      }
      var cur = _quickFirst(_queue.removeFirst());
      var curClip = _synth(cur);
      var failures = 0;
      while (alive()) {
        // Keep one page queued ahead when we can read ahead (PDF).
        if (_queue.isEmpty && source.canPeek) {
          await _loadPage(1 + _peeked, 1);
          _peeked++;
        }
        final next = _queue.isEmpty ? null : _queue.removeFirst();
        final nextClip = next == null ? null : _synth(next);

        final clip = await curClip;
        if (!alive()) return;
        for (var i = 0; i < cur.turnsBefore; i++) {
          await source.turnNext();
          _peeked = (_peeked - 1).clamp(0, 1 << 30);
        }
        if (clip != null) {
          failures = 0;
          await _play(clip, g);
          if (!alive()) return;
        } else if (++failures >= 3) {
          throw Exception(_lastFailure ?? 'speech failed');
        }

        if (next == null) {
          if (source.canPeek) break; // end of the book
          // EPUB: turn the page now that it has been read, then read on.
          if (!await source.turnNext() || !alive()) break;
          if (!await _loadPage(0, 0) || !alive()) break;
          cur = _queue.removeFirst();
          curClip = _synth(cur);
        } else {
          cur = next;
          curClip = nextClip!;
        }
      }
      if (alive()) await stop();
    } catch (e) {
      if (!alive()) return;
      debugPrint('Read aloud failed: $e');
      final why = '$e'.replaceFirst('Exception: ', '');
      onNotice?.call('Reading aloud stopped because of a problem ($why).');
      await stop();
    }
  }

  Future<void> _play(Clip clip, int g) async {
    final done = _clipDone = Completer<void>();
    await _player.setFilePath(clip.path);
    if (g != _gen) return;
    if (_state == ReadAloudState.starting) _set(ReadAloudState.playing);
    if (_state == ReadAloudState.playing) unawaited(_player.play());
    await done.future;
  }

  @override
  void dispose() {
    _gen++;
    _finishClip();
    _playerSub?.cancel();
    _noisySub?.cancel();
    _interruptSub?.cancel();
    _player.dispose();
    super.dispose();
  }
}
