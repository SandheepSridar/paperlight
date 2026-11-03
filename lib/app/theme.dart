import 'package:flutter/material.dart';

enum PageTheme { light, sepia, dark }

extension PageThemeColors on PageTheme {
  Color get background => switch (this) {
        PageTheme.light => const Color(0xFFFFFFFF),
        PageTheme.sepia => const Color(0xFFF6EDDC),
        PageTheme.dark => const Color(0xFF000000), // true black saves OLED power
      };
  Color get foreground => switch (this) {
        PageTheme.light => const Color(0xFF1A1A1A),
        PageTheme.sepia => const Color(0xFF433422),
        PageTheme.dark => const Color(0xFFCFCFCF),
      };
  String get label => switch (this) {
        PageTheme.light => 'White',
        PageTheme.sepia => 'Sepia',
        PageTheme.dark => 'Night',
      };

  /// Colour filter applied to rendered PDF pages so they match the theme.
  ColorFilter? get pdfFilter => switch (this) {
        PageTheme.light => null,
        // Warm tint: keeps white as paper colour, darkens slightly to brown.
        PageTheme.sepia => const ColorFilter.matrix([
            0.96, 0, 0, 0, 0, //
            0, 0.93, 0, 0, 0,
            0, 0, 0.86, 0, 0,
            0, 0, 0, 1, 0,
          ]),
        // Invert, then soften whites to light grey so it's easy on the eyes.
        PageTheme.dark => const ColorFilter.matrix([
            -0.81, 0, 0, 0, 207, //
            0, -0.81, 0, 0, 207,
            0, 0, -0.81, 0, 207,
            0, 0, 0, 1, 0,
          ]),
      };
}

const _seed = Color(0xFF8A5A2B);

ThemeData buildAppTheme(Brightness brightness) {
  final scheme = ColorScheme.fromSeed(seedColor: _seed, brightness: brightness);
  final base = ThemeData(colorScheme: scheme, useMaterial3: true);
  return base.copyWith(
    scaffoldBackgroundColor:
        brightness == Brightness.dark ? Colors.black : const Color(0xFFFBF8F3),
    textTheme: base.textTheme.apply(fontSizeFactor: 1.08),
    // Generous touch targets for a beginner.
    materialTapTargetSize: MaterialTapTargetSize.padded,
    visualDensity: VisualDensity.standard,
    iconButtonTheme: IconButtonThemeData(
      style: IconButton.styleFrom(minimumSize: const Size(52, 52), iconSize: 26),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        minimumSize: const Size(64, 56),
        textStyle: const TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      ),
    ),
    sliderTheme: const SliderThemeData(trackHeight: 6),
  );
}
