import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'theme.dart';

enum ReadingFont { serif, sans, easy }

extension ReadingFontCss on ReadingFont {
  String get label => switch (this) {
        ReadingFont.serif => 'Classic',
        ReadingFont.sans => 'Modern',
        ReadingFont.easy => 'Easy read',
      };
  String get css => switch (this) {
        ReadingFont.serif => 'Georgia, "Noto Serif", serif',
        ReadingFont.sans => 'Roboto, "Noto Sans", sans-serif',
        ReadingFont.easy => 'Verdana, "Noto Sans", sans-serif',
      };
  String get flutterFamily => switch (this) {
        ReadingFont.serif => 'serif',
        _ => 'sans-serif',
      };
}

enum PdfMode { pages, scroll }

/// Reading preferences, shared by every book so the experience stays
/// consistent (like Kindle). Persisted with shared_preferences.
class ReaderPrefs extends ChangeNotifier {
  ReaderPrefs(this._sp);
  final SharedPreferences _sp;

  static const fontSizes = [15, 18, 21, 25, 30];
  static const lineHeights = [1.4, 1.65, 1.9];
  static const marginSizes = [8.0, 28.0, 56.0];

  PageTheme get theme =>
      PageTheme.values[_sp.getInt('theme') ?? PageTheme.light.index];
  set theme(PageTheme v) => _set('theme', v.index);

  int get fontStep => _sp.getInt('fontStep') ?? 1;
  set fontStep(int v) => _set('fontStep', v.clamp(0, fontSizes.length - 1));
  int get fontSize => fontSizes[fontStep];

  ReadingFont get font =>
      ReadingFont.values[_sp.getInt('font') ?? ReadingFont.serif.index];
  set font(ReadingFont v) => _set('font', v.index);

  int get lineStep => _sp.getInt('lineStep') ?? 1;
  set lineStep(int v) => _set('lineStep', v.clamp(0, lineHeights.length - 1));
  double get lineHeight => lineHeights[lineStep];

  int get marginStep => _sp.getInt('marginStep') ?? 1;
  set marginStep(int v) =>
      _set('marginStep', v.clamp(0, marginSizes.length - 1));
  double get margin => marginSizes[marginStep];

  PdfMode get pdfMode => PdfMode.values[_sp.getInt('pdfMode') ?? 0];
  set pdfMode(PdfMode v) => _set('pdfMode', v.index);

  bool get keepScreenOn => _sp.getBool('keepScreenOn') ?? false;
  set keepScreenOn(bool v) {
    _sp.setBool('keepScreenOn', v);
    notifyListeners();
  }

  /// null = follow the system brightness.
  double? get brightness => _sp.getDouble('brightness');
  set brightness(double? v) {
    v == null ? _sp.remove('brightness') : _sp.setDouble('brightness', v);
    notifyListeners();
  }

  bool get seenReaderTip => _sp.getBool('seenReaderTip_v1_1') ?? false;
  set seenReaderTip(bool v) => _sp.setBool('seenReaderTip_v1_1', v);

  DateTime? get lastUpdateCheck {
    final ms = _sp.getInt('lastUpdateCheck');
    return ms == null ? null : DateTime.fromMillisecondsSinceEpoch(ms);
  }

  set lastUpdateCheck(DateTime? v) =>
      _sp.setInt('lastUpdateCheck', v?.millisecondsSinceEpoch ?? 0);

  void _set(String k, int v) {
    _sp.setInt(k, v);
    notifyListeners();
  }
}
