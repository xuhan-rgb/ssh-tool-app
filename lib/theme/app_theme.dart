import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:xterm/xterm.dart';

class _Palette {
  final Color deep, surface, card, elevated, hover, border, borderAccent;
  final Color text, secondary, muted, green, red, orange, blue, purple, cyan;

  const _Palette({
    required this.deep,
    required this.surface,
    required this.card,
    required this.elevated,
    required this.hover,
    required this.border,
    required this.borderAccent,
    required this.text,
    required this.secondary,
    required this.muted,
    required this.green,
    required this.red,
    required this.orange,
    required this.blue,
    required this.purple,
    required this.cyan,
  });
}

/// 终端风格暗色主题 — 集中定义所有颜色和样式常量
class AppTheme {
  AppTheme._();

  static const schemes = <String, String>{
    'dark': '深色',
    'light': '浅色',
    'violet': '紫夜',
  };
  static final selectedScheme = ValueNotifier<String>('dark');
  static void select(String scheme) {
    selectedScheme.value = schemes.containsKey(scheme) ? scheme : 'dark';
    SystemChrome.setSystemUIOverlayStyle(SystemUiOverlayStyle(
      statusBarColor: Colors.transparent,
      statusBarIconBrightness: isLight ? Brightness.dark : Brightness.light,
      systemNavigationBarColor: bgDeep,
      systemNavigationBarIconBrightness:
          isLight ? Brightness.dark : Brightness.light,
    ));
  }

  static const _dark = _Palette(
    deep: Color(0xFF0A0E14), surface: Color(0xFF111720),
    card: Color(0xFF151C28), elevated: Color(0xFF1A2233),
    hover: Color(0xFF1E2940), border: Color(0xFF1E2940),
    borderAccent: Color(0xFF2A3A52), text: Color(0xFFE6EDF3),
    secondary: Color(0xFF8B9AB5), muted: Color(0xFF546178),
    green: Color(0xFF3FB950), red: Color(0xFFF85149),
    orange: Color(0xFFD29922), blue: Color(0xFF58A6FF),
    purple: Color(0xFFBC8CFF), cyan: Color(0xFF39D4E0),
  );
  static const _light = _Palette(
    deep: Color(0xFFFFFFFF), surface: Color(0xFFF7F8FA),
    card: Color(0xFFF2F4F7), elevated: Color(0xFFE8EDF3),
    hover: Color(0xFFE9EEF5), border: Color(0xFFDDE3EB),
    borderAccent: Color(0xFFC7D1DF), text: Color(0xFF17212F),
    secondary: Color(0xFF4B5563), muted: Color(0xFF697586),
    green: Color(0xFF15803D), red: Color(0xFFDC2626),
    orange: Color(0xFFB45309), blue: Color(0xFF2563EB),
    purple: Color(0xFF7C3AED), cyan: Color(0xFF0284C7),
  );
  static const _violet = _Palette(
    deep: Color(0xFF120F1B), surface: Color(0xFF1B1727),
    card: Color(0xFF241E34), elevated: Color(0xFF30283F),
    hover: Color(0xFF3A3150), border: Color(0xFF352C49),
    borderAccent: Color(0xFF4B3C65), text: Color(0xFFF0EAF7),
    secondary: Color(0xFFB8AACD), muted: Color(0xFF827295),
    green: Color(0xFF62C68A), red: Color(0xFFFF6B7E),
    orange: Color(0xFFE9AF62), blue: Color(0xFF9F9BFF),
    purple: Color(0xFFC69BFF), cyan: Color(0xFF80CFF0),
  );
  static _Palette get _colors => switch (selectedScheme.value) {
        'light' => _light,
        'violet' => _violet,
        _ => _dark,
      };
  static bool get isLight => selectedScheme.value == 'light';

  // ===== 背景色层级 =====
  static Color get bgDeep => _colors.deep;
  static Color get bgSurface => _colors.surface;
  static Color get bgCard => _colors.card;
  static Color get bgElevated => _colors.elevated;
  static Color get bgHover => _colors.hover;

  // ===== 边框 =====
  static Color get borderSubtle => _colors.border;
  static Color get borderAccent => _colors.borderAccent;

  // ===== 文字 =====
  static Color get textPrimary => _colors.text;
  static Color get textSecondary => _colors.secondary;
  static Color get textMuted => _colors.muted;

  // ===== 语义色 =====
  static Color get green => _colors.green;
  static Color get red => _colors.red;
  static Color get orange => _colors.orange;
  static Color get blue => _colors.blue;
  static Color get purple => _colors.purple;
  static Color get cyan => _colors.cyan;

  // ===== 语义色淡底 =====
  static Color get greenDim => green.withValues(alpha: 0.15);
  static Color get redDim => red.withValues(alpha: 0.12);
  static Color get orangeDim => orange.withValues(alpha: 0.15);
  static Color get blueDim => blue.withValues(alpha: 0.12);
  static Color get purpleDim => purple.withValues(alpha: 0.12);
  static Color get cyanDim => cyan.withValues(alpha: 0.10);

  // ===== 会话类型专用色 =====
  static Color get shellColor => cyan;
  static Color get claudeColor => purple;
  static Color get codexColor => blue;

  static Color get chatUserBubble =>
      isLight ? const Color(0xFFDDEBFF) : const Color(0xFF25415F);

  static TerminalTheme get terminalTheme => TerminalTheme(
        cursor: textPrimary,
        selection: blue.withValues(alpha: 0.35),
        foreground: textPrimary,
        background: bgDeep,
        black: isLight ? const Color(0xFF17212F) : const Color(0xFF000000),
        white: isLight ? const Color(0xFFE8EDF3) : const Color(0xFFE5E5E5),
        red: red, green: green, yellow: orange, blue: blue,
        magenta: purple, cyan: cyan,
        brightBlack: textMuted, brightRed: red, brightGreen: green,
        brightYellow: orange, brightBlue: blue, brightMagenta: purple,
        brightCyan: cyan, brightWhite: textPrimary,
        searchHitBackground: orange.withValues(alpha: 0.5),
        searchHitBackgroundCurrent: green.withValues(alpha: 0.5),
        searchHitForeground: textPrimary,
      );

  // ===== ThemeData =====
  static ThemeData get darkTheme {
    return ThemeData(
      useMaterial3: true,
      brightness: isLight ? Brightness.light : Brightness.dark,
      scaffoldBackgroundColor: bgDeep,
      colorScheme: ColorScheme.fromSeed(
        seedColor: cyan,
        brightness: isLight ? Brightness.light : Brightness.dark,
        surface: bgSurface,
        primary: cyan,
        secondary: purple,
        error: red,
        onSurface: textPrimary,
        onPrimary: bgDeep,
        onSecondary: bgDeep,
        outline: borderSubtle,
        outlineVariant: borderAccent,
        surfaceContainerHighest: bgSurface,
      ),
      cardColor: bgCard,
      cardTheme: CardThemeData(
        color: bgCard,
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(14),
          side: BorderSide(color: borderSubtle, width: 1),
        ),
        margin: const EdgeInsets.symmetric(vertical: 5, horizontal: 0),
      ),
      appBarTheme: AppBarTheme(
        backgroundColor: bgSurface,
        foregroundColor: textPrimary,
        elevation: 0,
        scrolledUnderElevation: 0,
        surfaceTintColor: Colors.transparent,
        titleTextStyle: TextStyle(
          fontFamily: 'monospace',
          fontSize: 17,
          fontWeight: FontWeight.w600,
          color: textPrimary,
        ),
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: bgCard,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(14),
          side: BorderSide(color: borderAccent, width: 1),
        ),
        titleTextStyle: TextStyle(
          fontSize: 17,
          fontWeight: FontWeight.w700,
          color: textPrimary,
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: bgDeep,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: BorderSide(color: borderAccent),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: BorderSide(color: borderAccent),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: BorderSide(color: cyan, width: 1.5),
        ),
        labelStyle: TextStyle(color: textSecondary),
        hintStyle: TextStyle(color: textMuted),
        prefixIconColor: textMuted,
        isDense: true,
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          backgroundColor: cyan,
          foregroundColor: bgDeep,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
          textStyle: const TextStyle(fontWeight: FontWeight.w600, fontSize: 14),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          foregroundColor: textSecondary,
        ),
      ),
      switchTheme: SwitchThemeData(
        thumbColor: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.selected)) return cyan;
          return textMuted;
        }),
        trackColor: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.selected)) return cyan.withValues(alpha: 0.3);
          return borderSubtle;
        }),
      ),
      popupMenuTheme: PopupMenuThemeData(
        color: bgElevated,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(10),
          side: BorderSide(color: borderAccent),
        ),
      ),
      snackBarTheme: SnackBarThemeData(
        backgroundColor: bgElevated,
        contentTextStyle: TextStyle(color: textPrimary, fontSize: 13),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
        behavior: SnackBarBehavior.floating,
      ),
      bottomSheetTheme: BottomSheetThemeData(
        backgroundColor: bgCard,
      ),
      listTileTheme: ListTileThemeData(
        iconColor: textSecondary,
        textColor: textPrimary,
      ),
      dividerColor: borderSubtle,
    );
  }
}
