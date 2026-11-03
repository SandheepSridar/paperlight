import 'package:flutter/services.dart';
import 'package:screen_brightness/screen_brightness.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import '../../app/prefs.dart';

/// Full-screen, brightness and keep-awake state while a book is open.
/// Everything is undone in [end] so the rest of the tablet is unaffected.
class ReaderSession {
  ReaderSession(this.prefs);
  final ReaderPrefs prefs;

  void begin() {
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    apply();
  }

  /// Re-applies brightness / wakelock after a preference change.
  void apply() {
    final b = prefs.brightness;
    try {
      b == null
          ? ScreenBrightness.instance.resetApplicationScreenBrightness()
          : ScreenBrightness.instance.setApplicationScreenBrightness(b);
    } catch (_) {}
    try {
      prefs.keepScreenOn ? WakelockPlus.enable() : WakelockPlus.disable();
    } catch (_) {}
  }

  void end() {
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    try {
      ScreenBrightness.instance.resetApplicationScreenBrightness();
    } catch (_) {}
    try {
      WakelockPlus.disable();
    } catch (_) {}
  }
}
