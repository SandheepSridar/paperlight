import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sherpa_onnx/sherpa_onnx.dart' as sherpa;

/// How a voice pronounces English: which pronunciation dictionary and
/// eSpeak language the engine runs with.
enum Accent {
  american('lexicon-us-en.txt', 'en-us'),
  british('lexicon-gb-en.txt', 'en');

  const Accent(this.lexicon, this.lang);
  final String lexicon;
  final String lang;
}

/// A narrator the reader can pick. [sid] is the Kokoro v1.0 speaker id.
class Voice {
  const Voice(this.id, this.name, this.description, this.sid, this.accent);
  final String id;
  final String name;
  final String description;
  final int sid;
  final Accent accent;
}

const voices = [
  Voice('heart', 'Heart', 'Warm, American', 3, Accent.american),
  Voice('bella', 'Bella', 'Bright, American', 2, Accent.american),
  Voice('michael', 'Michael', 'Calm, American', 16, Accent.american),
  Voice('emma', 'Emma', 'Gentle, British', 21, Accent.british),
  Voice('george', 'George', 'Deep, British', 26, Accent.british),
  // Kokoro's Hindi voices reading English give a natural Indian accent.
  Voice('ananya', 'Ananya', 'Soft, Indian', 31, Accent.american),
  Voice('priya', 'Priya', 'Clear, Indian', 32, Accent.american),
  Voice('arjun', 'Arjun', 'Warm, Indian', 33, Accent.american),
  Voice('rohan', 'Rohan', 'Steady, Indian', 34, Accent.american),
];

Voice voiceById(String? id) =>
    voices.firstWhere((v) => v.id == id, orElse: () => voices.first);

/// The Kokoro v1.0 neural voice: downloaded once, on request, then kept in
/// the app's private storage so reading aloud works offline.
///
/// Files come from a pinned Hugging Face revision of sherpa-onnx's model
/// repo and are checked against fixed hashes. Only the English part of the
/// eSpeak data is fetched (it pronounces words missing from the lexicon).
class VoiceModel {
  VoiceModel._();
  static final instance = VoiceModel._();

  static const _name = 'kokoro-int8-multi-lang-v1_0';
  static const _base = 'https://huggingface.co/csukuangfj/$_name/resolve/'
      '57adb37fc0e8d4bd430cfc1b8f8c2294945b9af2';
  static const _files = [
    ('model.int8.onnx', 114202993, '75635ea3b85a32d00094dcdd61a258aba87c160f7c264c304a7b3ae9d734195e'),
    ('voices.bin', 28200960, '1c5a5b983d3d50d8586d437a51f3faa2da7919ce76a013c081e65671a3447c29'),
    ('tokens.txt', 687, '6ebb6bb288f20f3ae8d004d3c2ca27697da27c037d75e81a60e2a6a663f95425'),
    ('lexicon-us-en.txt', 5956885, '7daaab53a181be9885b853a8582bf1838186317e5dadacbcef9c426d6fa0da14'),
    ('lexicon-gb-en.txt', 6366635, 'c4cbb37316f62210dff52718a7afcaae24f50c032cc75ab47ae67b831d1049e7'),
    ('LICENSE', 11358, 'cfc7749b96f63bd31c3c42b5c471bf756814053e847c10f3eb003417bc523d30'),
    ('espeak-ng-data/en_dict', 166944, '71bd330ba8a2e3e8076e631508208ef49449d6147c17b7bd2b4b1e1468292e35'),
    ('espeak-ng-data/intonations', 2040, '3f8af65fd3eda9759a10f021d61361c120871f463515229c925995c7f90918cc'),
    ('espeak-ng-data/phondata', 550424, '4e0288957874029a8c3c9f41a8f517ad4bf18127046decbdd4b9d1d6807ce3a3'),
    ('espeak-ng-data/phondata-manifest', 21821, '7b387af0702c7cf0b61f0bead68feded0bd8e1620729b0b252e76acbc30d3813'),
    ('espeak-ng-data/phonindex', 39074, '3ca7b8fa3b42624e4b0f152707e7a39245fce569aa99ea47c055d9e622fcf0c4'),
    ('espeak-ng-data/phontab', 55796, '886f3fa402cb0ba73d483aa8ad000af47a6b7cc06293c75a97913fba68a530f6'),
    ('espeak-ng-data/lang/gmw/en', 140, '4605d5330801de3641c6e366d15f129ea1f5ffbce8722642aba01ace07ab9c83'),
    ('espeak-ng-data/lang/gmw/en-US', 257, '41534c2a22df5dd4f1052ff9e1a33a3ea7bff5a26b5c02bdad5ba8ddb7524704'),
  ];
  static int get _totalBytes => _files.fold(0, (a, f) => a + f.$2);
  static const downloadMb = 156;
  static const installedMb = 156;

  Future<Directory> _root() async =>
      Directory(p.join((await getApplicationSupportDirectory()).path, 'voices'));

  Future<String> modelDir() async => p.join((await _root()).path, _name);

  Future<bool> isInstalled() async =>
      File(p.join(await modelDir(), '.installed')).exists();

  /// True when an older voice model (from an earlier version) is installed.
  Future<bool> hasOlderVoice() async {
    final root = await _root();
    if (!await root.exists()) return false;
    await for (final e in root.list()) {
      if (p.basename(e.path) != _name &&
          await File(p.join(e.path, '.installed')).exists()) {
        return true;
      }
    }
    return false;
  }

  /// Downloads and verifies the model. [onProgress] gets 0..1. Throws on
  /// failure. Files already downloaded intact (from an interrupted attempt)
  /// are kept, so trying again carries on where it stopped.
  Future<void> install({void Function(double?)? onProgress, bool Function()? cancelled}) async {
    final root = await _root();
    final dir = await modelDir();
    await Directory(dir).create(recursive: true);
    final client = http.Client();
    var done = 0;
    try {
      for (final (name, size, hash) in _files) {
        final file = File(p.join(dir, name));
        if (await file.exists() && await file.length() == size &&
            (await sha256.bind(file.openRead()).first).toString() == hash) {
          done += size;
          onProgress?.call(done / _totalBytes);
          continue;
        }
        await file.parent.create(recursive: true);
        final part = File('${file.path}.part');
        final res = await client.send(http.Request('GET', Uri.parse('$_base/$name')));
        if (res.statusCode != 200) throw HttpException('HTTP ${res.statusCode} for $name');
        final sink = part.openWrite();
        final digest = _DigestSink();
        final hasher = sha256.startChunkedConversion(digest);
        try {
          await for (final chunk in res.stream) {
            if (cancelled?.call() == true) throw const _Cancelled();
            sink.add(chunk);
            hasher.add(chunk);
            done += chunk.length;
            onProgress?.call((done / _totalBytes).clamp(0.0, 1.0));
          }
        } finally {
          await sink.close();
        }
        hasher.close();
        if (digest.value.toString() != hash) {
          await part.delete();
          throw FileSystemException('The voice download was damaged ($name).');
        }
        await part.rename(file.path);
      }
      await File(p.join(dir, '.installed')).writeAsString('ok');
      // Remove any older voice model to free its space.
      await for (final e in root.list()) {
        if (p.basename(e.path) != _name) await e.delete(recursive: true);
      }
    } finally {
      client.close();
    }
  }

  Future<void> remove() async {
    await VoiceEngine.instance.shutdown();
    final root = await _root();
    if (await root.exists()) await root.delete(recursive: true);
  }
}

class _Cancelled implements Exception {
  const _Cancelled();
}

bool isCancelled(Object e) => e is _Cancelled;

class _DigestSink implements Sink<Digest> {
  late Digest value;
  @override
  void add(Digest data) => value = data;
  @override
  void close() {}
}

/// A synthesised clip on disk.
class Clip {
  const Clip(this.path, this.duration);
  final String path;
  final Duration duration;
}

/// Runs the neural voice on a background isolate so generating speech never
/// stutters the page. Requests are handled in order, one at a time.
class VoiceEngine {
  VoiceEngine._();
  static final instance = VoiceEngine._();

  Isolate? _isolate;
  SendPort? _send;
  Future<void>? _starting;
  Accent? _accent;
  final _pending = <int, Completer<Clip>>{};
  var _nextId = 0;
  var _clipNo = 0;
  ReceivePort? _receive;
  String? _cacheDir;

  /// Starts the engine for [accent], restarting it if it was running with
  /// a different pronunciation dictionary.
  Future<void> start(Accent accent) async {
    if (_accent != accent && _starting != null) await shutdown();
    _accent = accent;
    return _starting ??= _start(accent);
  }

  Future<void> _start(Accent accent) async {
    final dir = await VoiceModel.instance.modelDir();
    final cache = Directory(p.join((await getTemporaryDirectory()).path, 'narration'));
    if (await cache.exists()) await cache.delete(recursive: true);
    await cache.create(recursive: true);
    _cacheDir = cache.path;

    final receive = ReceivePort();
    _receive = receive;
    final ready = Completer<SendPort>();
    receive.listen((msg) {
      if (msg is SendPort) {
        ready.complete(msg);
      } else if (msg is List) {
        final c = _pending.remove(msg[0] as int);
        if (msg[1] == null) {
          c?.completeError(Exception(msg[2] ?? 'Speech failed'));
        } else {
          c?.complete(Clip(msg[1] as String, Duration(milliseconds: msg[2] as int)));
        }
      } else if (msg is String && !ready.isCompleted) {
        ready.completeError(Exception(msg));
      }
    });
    try {
      _isolate = await Isolate.spawn(
          _worker, [receive.sendPort, dir, accent.lexicon, accent.lang],
          debugName: 'voice');
      _send = await ready.future;
    } catch (e) {
      _starting = null;
      _accent = null;
      receive.close();
      rethrow;
    }
  }

  /// Speaks [text] into a WAV file. Silence the model leaves at either end
  /// is trimmed and exactly [pauseAfter] is added, so clips played back to
  /// back have natural, even gaps.
  Future<Clip> synthesize(String text,
      {required Voice voice, double speed = 1.0, Duration pauseAfter = Duration.zero}) async {
    await start(voice.accent);
    final id = _nextId++;
    final c = _pending[id] = Completer<Clip>();
    final path = p.join(_cacheDir!, 'clip${_clipNo++}.wav');
    _send!.send([id, text, voice.sid, speed, pauseAfter.inMilliseconds, path]);
    return c.future;
  }

  Future<void> shutdown() async {
    _isolate?.kill(priority: Isolate.immediate);
    _isolate = null;
    _send = null;
    _starting = null;
    _accent = null;
    _receive?.close();
    _receive = null;
    for (final c in _pending.values) {
      c.completeError(Exception('Stopped'));
    }
    _pending.clear();
  }
}

/// Samples at the start and end quieter than this count as silence.
const _quiet = 0.01;

void _worker(List<Object?> args) {
  final reply = args[0] as SendPort;
  final dir = args[1] as String;
  final sherpa.OfflineTts tts;
  try {
    sherpa.initBindings();
    tts = sherpa.OfflineTts(sherpa.OfflineTtsConfig(
      model: sherpa.OfflineTtsModelConfig(
        kokoro: sherpa.OfflineTtsKokoroModelConfig(
          model: p.join(dir, 'model.int8.onnx'),
          voices: p.join(dir, 'voices.bin'),
          tokens: p.join(dir, 'tokens.txt'),
          lexicon: p.join(dir, args[2] as String),
          lang: args[3] as String,
          dataDir: p.join(dir, 'espeak-ng-data'),
        ),
        numThreads: Platform.numberOfProcessors >= 8 ? 4 : 2,
      ),
      // Shortens the model's own pauses between sentences inside a chunk.
      silenceScale: 0.25,
    ));
  } catch (e) {
    reply.send('Could not start the voice: $e');
    return;
  }
  final port = ReceivePort();
  reply.send(port.sendPort);
  port.listen((msg) {
    final m = msg as List;
    final id = m[0] as int;
    try {
      final audio = tts.generate(
          text: m[1] as String, sid: m[2] as int, speed: m[3] as double);
      final s = audio.samples;
      final rate = audio.sampleRate;
      var start = 0, end = s.length;
      while (start < end && s[start].abs() <= _quiet) {
        start++;
      }
      while (end > start && s[end - 1].abs() <= _quiet) {
        end--;
      }
      if (end <= start) throw Exception('No audio');
      // Keep a whisker of the natural fade at each end.
      final edge = (rate * 0.03).round();
      start = (start - edge).clamp(0, s.length);
      end = (end + edge).clamp(0, s.length);
      final pad = (rate * (m[4] as int) / 1000).round();
      final out = Float32List(end - start + pad)..setRange(0, end - start, s, start);
      final path = m[5] as String;
      if (!sherpa.writeWave(filename: path, samples: out, sampleRate: rate)) {
        throw Exception('Could not write audio');
      }
      reply.send([id, path, (out.length * 1000 / rate).round()]);
    } catch (e) {
      reply.send([id, null, '$e']);
    }
  });
}
