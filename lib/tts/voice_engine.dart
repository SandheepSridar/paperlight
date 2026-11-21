import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:archive/archive_io.dart';
import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sherpa_onnx/sherpa_onnx.dart' as sherpa;

/// A narrator the reader can pick. [sid] is the Kokoro speaker id.
class Voice {
  const Voice(this.id, this.name, this.description, this.sid);
  final String id;
  final String name;
  final String description;
  final int sid;
}

const voices = [
  Voice('bella', 'Bella', 'Warm, American', 1),
  Voice('michael', 'Michael', 'Calm, American', 6),
  Voice('emma', 'Emma', 'Gentle, British', 7),
  Voice('george', 'George', 'Deep, British', 9),
];

Voice voiceById(String? id) =>
    voices.firstWhere((v) => v.id == id, orElse: () => voices.first);

/// The Kokoro neural voice model: downloaded once, on request, then kept in
/// the app's private storage so reading aloud works offline.
class VoiceModel {
  VoiceModel._();
  static final instance = VoiceModel._();

  static const _name = 'kokoro-int8-en-v0_19';
  static const _url =
      'https://github.com/k2-fsa/sherpa-onnx/releases/download/tts-models/$_name.tar.bz2';
  static const _sha256 =
      'c9f0dd393615805b0bab050c340834d5e684e732aec91c0e860cd30e982c08bd';
  static const downloadMb = 103;
  static const installedMb = 152;

  Future<Directory> _root() async =>
      Directory(p.join((await getApplicationSupportDirectory()).path, 'voices'));

  Future<String> modelDir() async => p.join((await _root()).path, _name);

  Future<bool> isInstalled() async =>
      File(p.join(await modelDir(), '.installed')).exists();

  /// Downloads, verifies and unpacks the model. [onProgress] gets 0..1 while
  /// downloading and null while unpacking. Throws on failure.
  Future<void> install({void Function(double?)? onProgress, bool Function()? cancelled}) async {
    final root = await _root();
    await root.create(recursive: true);
    final archive = File(p.join(root.path, '$_name.tar.bz2'));
    final client = http.Client();
    try {
      final res = await client.send(http.Request('GET', Uri.parse(_url)));
      if (res.statusCode != 200) throw HttpException('HTTP ${res.statusCode}');
      final total = res.contentLength ?? downloadMb * 1000 * 1000;
      final sink = archive.openWrite();
      final digest = _DigestSink();
      final hasher = sha256.startChunkedConversion(digest);
      var got = 0;
      try {
        await for (final chunk in res.stream) {
          if (cancelled?.call() == true) throw const _Cancelled();
          sink.add(chunk);
          hasher.add(chunk);
          got += chunk.length;
          onProgress?.call((got / total).clamp(0.0, 1.0));
        }
      } finally {
        await sink.close();
      }
      hasher.close();
      if (digest.value.toString() != _sha256) {
        throw const FileSystemException('The voice download was damaged.');
      }
      onProgress?.call(null);
      final dir = Directory(await modelDir());
      if (await dir.exists()) await dir.delete(recursive: true);
      final out = root.path;
      final path = archive.path;
      await Isolate.run(() => extractFileToDisk(path, out));
      await File(p.join(dir.path, '.installed')).writeAsString(_sha256);
    } finally {
      client.close();
      if (await archive.exists()) await archive.delete();
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
  final _pending = <int, Completer<Clip>>{};
  var _nextId = 0;
  var _clipNo = 0;
  ReceivePort? _receive;
  String? _cacheDir;

  Future<void> start() => _starting ??= _start();

  Future<void> _start() async {
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
      _isolate = await Isolate.spawn(_worker, [receive.sendPort, dir],
          debugName: 'voice');
      _send = await ready.future;
    } catch (e) {
      _starting = null;
      receive.close();
      rethrow;
    }
  }

  /// Speaks [text] into a WAV file, followed by [pauseAfter] of silence
  /// (so clips play back to back with natural gaps).
  Future<Clip> synthesize(String text,
      {required int sid, double speed = 1.0, Duration pauseAfter = Duration.zero}) async {
    await start();
    final id = _nextId++;
    final c = _pending[id] = Completer<Clip>();
    final path = p.join(_cacheDir!, 'clip${_clipNo++ % 8}.wav');
    _send!.send([id, text, sid, speed, pauseAfter.inMilliseconds, path]);
    return c.future;
  }

  Future<void> shutdown() async {
    _isolate?.kill(priority: Isolate.immediate);
    _isolate = null;
    _send = null;
    _starting = null;
    _receive?.close();
    _receive = null;
    for (final c in _pending.values) {
      c.completeError(Exception('Stopped'));
    }
    _pending.clear();
  }
}

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
          dataDir: p.join(dir, 'espeak-ng-data'),
        ),
        numThreads: Platform.numberOfProcessors >= 8 ? 4 : 2,
      ),
      // Let the model see a couple of sentences at once for better flow.
      maxNumSentences: 2,
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
      if (audio.samples.isEmpty) throw Exception('No audio');
      final pad = (audio.sampleRate * (m[4] as int) / 1000).round();
      final samples = Float32List(audio.samples.length + pad)
        ..setRange(0, audio.samples.length, audio.samples);
      final path = m[5] as String;
      if (!sherpa.writeWave(
          filename: path, samples: samples, sampleRate: audio.sampleRate)) {
        throw Exception('Could not write audio');
      }
      reply.send(
          [id, path, (samples.length * 1000 / audio.sampleRate).round()]);
    } catch (e) {
      reply.send([id, null, '$e']);
    }
  });
}
