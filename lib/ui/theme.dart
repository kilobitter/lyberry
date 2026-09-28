import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Redline palette: near-black ground, one restrained signal red.
abstract final class LyberryColors {
  static const Color background = Color(0xFF111416);
  static const Color surface = Color(0xFF1B1F22);
  static const Color surfaceHigh = Color(0xFF23282B);
  static const Color ink = Color(0xFFF3F4EE);
  static const Color muted = Color(0xFFA2A7AB);
  static const Color signal = Color(0xFFF24C3E);
  static const Color rule = Color(0xFF363A3D);
}

abstract final class LyberryMetrics {
  static const double corner = 4;
  static const double gutter = 20;
  static const double touchTarget = 48;
}

/// Oxanium carries brand and page headings; everything readable stays on the
/// platform sans so body copy keeps native legibility.
abstract final class LyberryType {
  static const String displayFamily = 'Oxanium';

  static TextStyle display({
    required double size,
    double weight = 600,
    double letterSpacing = 0,
    double? height,
    Color color = LyberryColors.ink,
  }) {
    return TextStyle(
      fontFamily: displayFamily,
      fontSize: size,
      height: height,
      letterSpacing: letterSpacing,
      color: color,
      fontVariations: <FontVariation>[FontVariation('wght', weight)],
    );
  }

  /// Small uppercase label used for section headings and the masthead eyebrow.
  static TextStyle eyebrow({Color color = LyberryColors.muted}) => display(
    size: 11,
    weight: 600,
    letterSpacing: 2.2,
    height: 1.3,
    color: color,
  );

  static const TextStyle body = TextStyle(
    fontSize: 14,
    height: 1.4,
    color: LyberryColors.ink,
  );

  static const TextStyle bodyMuted = TextStyle(
    fontSize: 13,
    height: 1.35,
    color: LyberryColors.muted,
  );
}

ThemeData buildLyberryTheme() {
  const scheme = ColorScheme.dark(
    primary: LyberryColors.signal,
    onPrimary: LyberryColors.ink,
    secondary: LyberryColors.signal,
    onSecondary: LyberryColors.ink,
    surface: LyberryColors.surface,
    onSurface: LyberryColors.ink,
    error: LyberryColors.signal,
    onError: LyberryColors.ink,
  );

  final base = ThemeData(
    useMaterial3: true,
    brightness: Brightness.dark,
    colorScheme: scheme,
    scaffoldBackgroundColor: LyberryColors.background,
    canvasColor: LyberryColors.background,
    splashFactory: InkRipple.splashFactory,
  );

  // Button and chip labels derive from the platform text theme so they keep the
  // native family instead of falling back to a bare, family-less style.
  final buttonLabel = base.textTheme.labelLarge?.copyWith(
    fontSize: 15,
    fontWeight: FontWeight.w600,
  );
  final chipLabel = base.textTheme.labelLarge?.copyWith(fontSize: 13);

  return base.copyWith(
    textTheme: base.textTheme.apply(
      bodyColor: LyberryColors.ink,
      displayColor: LyberryColors.ink,
    ),
    dividerTheme: const DividerThemeData(
      color: LyberryColors.rule,
      thickness: 1,
      space: 1,
    ),
    appBarTheme: const AppBarTheme(
      backgroundColor: LyberryColors.background,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      centerTitle: false,
      titleTextStyle: TextStyle(
        fontFamily: LyberryType.displayFamily,
        fontSize: 18,
        fontWeight: FontWeight.w600,
        color: LyberryColors.ink,
      ),
      iconTheme: IconThemeData(color: LyberryColors.ink),
      systemOverlayStyle: SystemUiOverlayStyle(
        statusBarColor: Colors.transparent,
        statusBarIconBrightness: Brightness.light,
        statusBarBrightness: Brightness.dark,
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: LyberryColors.surface,
      isDense: true,
      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
      hintStyle: LyberryType.bodyMuted,
      labelStyle: LyberryType.bodyMuted,
      floatingLabelStyle: const TextStyle(color: LyberryColors.muted),
      border: _fieldBorder(LyberryColors.rule),
      enabledBorder: _fieldBorder(LyberryColors.rule),
      focusedBorder: _fieldBorder(LyberryColors.signal),
      errorBorder: _fieldBorder(LyberryColors.signal),
      focusedErrorBorder: _fieldBorder(LyberryColors.signal),
      errorStyle: const TextStyle(color: LyberryColors.signal, fontSize: 12),
    ),
    snackBarTheme: const SnackBarThemeData(
      backgroundColor: LyberryColors.surfaceHigh,
      contentTextStyle: TextStyle(color: LyberryColors.ink),
      behavior: SnackBarBehavior.floating,
    ),
    dialogTheme: const DialogThemeData(
      backgroundColor: LyberryColors.surface,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.all(Radius.circular(LyberryMetrics.corner)),
      ),
    ),
    chipTheme: base.chipTheme.copyWith(
      backgroundColor: LyberryColors.surface,
      selectedColor: LyberryColors.signal,
      side: const BorderSide(color: LyberryColors.rule),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.all(Radius.circular(LyberryMetrics.corner)),
      ),
      labelStyle: chipLabel?.copyWith(color: LyberryColors.ink),
      secondaryLabelStyle: chipLabel?.copyWith(color: LyberryColors.ink),
      showCheckmark: false,
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: LyberryColors.signal,
        foregroundColor: LyberryColors.ink,
        disabledBackgroundColor: LyberryColors.surfaceHigh,
        disabledForegroundColor: LyberryColors.muted,
        minimumSize: const Size(0, LyberryMetrics.touchTarget),
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.all(
            Radius.circular(LyberryMetrics.corner),
          ),
        ),
        textStyle: buttonLabel,
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        foregroundColor: LyberryColors.ink,
        minimumSize: const Size(0, LyberryMetrics.touchTarget),
        side: const BorderSide(color: LyberryColors.rule),
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.all(
            Radius.circular(LyberryMetrics.corner),
          ),
        ),
        textStyle: buttonLabel,
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(
        foregroundColor: LyberryColors.ink,
        minimumSize: const Size(0, LyberryMetrics.touchTarget),
        textStyle: base.textTheme.labelLarge?.copyWith(fontSize: 15),
      ),
    ),
    progressIndicatorTheme: const ProgressIndicatorThemeData(
      color: LyberryColors.signal,
    ),
  );
}

OutlineInputBorder _fieldBorder(Color color) => OutlineInputBorder(
  borderRadius: const BorderRadius.all(Radius.circular(LyberryMetrics.corner)),
  borderSide: BorderSide(color: color),
);
