import 'package:flutter/material.dart';
import 'package:timely_core/timely_core.dart';

Color hex(String s) => Color(int.parse(s.substring(1), radix: 16) | 0xFF000000);
String toHex(Color c) => '#${(c.toARGB32() & 0xFFFFFF).toRadixString(16).padLeft(6, '0')}';

/// Resolved palette for the current settings.
class Palette {
  final Color bg, fg, accent, muted, line, surface;
  Palette(TimelySettings s)
      : bg = hex(s.bg),
        fg = hex(s.fg),
        accent = hex(s.accent),
        muted = hex(s.muted),
        line = Color.lerp(hex(s.bg), hex(s.muted), 0.35)!,
        surface = Color.lerp(hex(s.bg), hex(s.fg), 0.04)!;

  bool get isDark => bg.computeLuminance() < 0.4;
}

ThemeData buildTheme(Palette p) {
  const font = 'JetBrainsMono';
  final base = ThemeData(
    useMaterial3: true,
    brightness: p.isDark ? Brightness.dark : Brightness.light,
    fontFamily: font,
  );
  final text = base.textTheme.apply(bodyColor: p.fg, displayColor: p.fg, fontFamily: font);
  final border = OutlineInputBorder(borderRadius: BorderRadius.zero, borderSide: BorderSide(color: p.line));
  return base.copyWith(
    scaffoldBackgroundColor: p.bg,
    canvasColor: p.bg,
    colorScheme: base.colorScheme.copyWith(
      primary: p.accent,
      onPrimary: p.bg,
      secondary: p.accent,
      surface: p.bg,
      onSurface: p.fg,
      outline: p.line,
      surfaceContainerHighest: p.surface,
    ),
    textTheme: text.copyWith(
      bodyMedium: text.bodyMedium?.copyWith(fontSize: 13, height: 1.5),
      bodySmall: text.bodySmall?.copyWith(fontSize: 11, color: p.muted),
      titleMedium: text.titleMedium?.copyWith(fontSize: 13, fontWeight: FontWeight.w500, letterSpacing: 0.5),
    ),
    dividerTheme: DividerThemeData(color: p.line, thickness: 1, space: 1),
    appBarTheme: AppBarTheme(
      backgroundColor: p.bg,
      foregroundColor: p.fg,
      elevation: 0,
      scrolledUnderElevation: 0,
      titleTextStyle: TextStyle(fontFamily: font, fontSize: 15, color: p.fg, letterSpacing: 1),
    ),
    inputDecorationTheme: InputDecorationTheme(
      border: border,
      enabledBorder: border,
      focusedBorder: border.copyWith(borderSide: BorderSide(color: p.accent)),
      labelStyle: TextStyle(color: p.muted),
      isDense: true,
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(
        foregroundColor: p.accent,
        shape: const RoundedRectangleBorder(),
        textStyle: const TextStyle(fontFamily: font, fontSize: 13),
      ),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: p.accent,
        foregroundColor: p.bg,
        shape: const RoundedRectangleBorder(),
        textStyle: const TextStyle(fontFamily: font, fontSize: 13, fontWeight: FontWeight.w500),
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
      ),
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: p.bg,
      shape: RoundedRectangleBorder(side: BorderSide(color: p.line)),
    ),
    bottomSheetTheme: BottomSheetThemeData(backgroundColor: p.bg, shape: const RoundedRectangleBorder()),
    snackBarTheme: SnackBarThemeData(
      backgroundColor: p.fg,
      contentTextStyle: TextStyle(fontFamily: font, color: p.bg),
      shape: const RoundedRectangleBorder(),
    ),
    progressIndicatorTheme: ProgressIndicatorThemeData(color: p.accent),
    iconTheme: IconThemeData(color: p.fg, size: 18),
    switchTheme: SwitchThemeData(
      thumbColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.selected) ? p.bg : p.muted),
      trackColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.selected) ? p.accent : p.surface),
    ),
  );
}
