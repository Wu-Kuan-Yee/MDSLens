import 'package:mdslens/i18n/localized_material.dart';
import 'package:flutter/foundation.dart';

class MDSLensTheme {
  static ThemeData light({
    String? fontFamily,
    double uiFontSize = 12,
    double iconSize = 22,
  }) {
    return _build(
      brightness: Brightness.light,
      seed: const Color(0xFF2563eb),
      scaffold: const Color(0xFFf6f6f6),
      card: const Color(0xFFffffff),
      fontFamily: fontFamily,
      uiFontSize: uiFontSize,
      iconSize: iconSize,
    );
  }

  static ThemeData dark({
    String? fontFamily,
    double uiFontSize = 12,
    double iconSize = 22,
  }) {
    return _build(
      brightness: Brightness.dark,
      seed: const Color(0xFF60a5fa),
      scaffold: const Color(0xFF111827),
      card: const Color(0xFF0f172a),
      fontFamily: fontFamily,
      uiFontSize: uiFontSize,
      iconSize: iconSize,
    );
  }

  static ThemeData _build({
    required Brightness brightness,
    required Color seed,
    required Color scaffold,
    required Color card,
    required String? fontFamily,
    required double uiFontSize,
    required double iconSize,
  }) {
    final base = ThemeData(
      useMaterial3: true,
      brightness: brightness,
      colorSchemeSeed: seed,
      scaffoldBackgroundColor: scaffold,
      cardColor: card,
      appBarTheme: AppBarTheme(backgroundColor: scaffold),
    );
    TextStyle? style(TextStyle? source, double size) => source?.copyWith(
          fontFamily: fontFamily,
          fontFamilyFallback: kIsWeb ? const ['MDSLens Noto Sans SC'] : null,
          fontSize: size.clamp(6, 48),
        );
    final source = base.textTheme;
    final colors = base.colorScheme;
    final textTheme = source.copyWith(
      displayLarge: style(source.displayLarge, uiFontSize + 32),
      displayMedium: style(source.displayMedium, uiFontSize + 24),
      displaySmall: style(source.displaySmall, uiFontSize + 18),
      headlineLarge: style(source.headlineLarge, uiFontSize + 14),
      headlineMedium: style(source.headlineMedium, uiFontSize + 12),
      headlineSmall: style(source.headlineSmall, uiFontSize + 10),
      titleLarge: style(source.titleLarge, uiFontSize + 8),
      titleMedium: style(source.titleMedium, uiFontSize + 4),
      titleSmall: style(source.titleSmall, uiFontSize + 2),
      bodyLarge: style(source.bodyLarge, uiFontSize + 2),
      bodyMedium: style(source.bodyMedium, uiFontSize),
      bodySmall: style(source.bodySmall, uiFontSize - 1),
      labelLarge: style(source.labelLarge, uiFontSize),
      labelMedium: style(source.labelMedium, uiFontSize - 1),
      labelSmall: style(source.labelSmall, uiFontSize - 2),
    );
    final buttonShape = RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(10),
    );
    final buttonText = textTheme.labelLarge?.copyWith(
      fontWeight: FontWeight.w600,
    );
    const buttonMinimumSize = Size(44, 44);
    const buttonPadding = EdgeInsets.symmetric(horizontal: 14, vertical: 10);
    return base.copyWith(
      iconTheme: base.iconTheme.copyWith(size: iconSize.clamp(18, 32)),
      textTheme: textTheme,
      primaryTextTheme: textTheme,
      // Keep the same semantic button type visually consistent everywhere:
      // dialogs, compact responsive toolbars, and desktop windows all share
      // one touch-friendly height, radius, and label weight. Individual
      // controls may still override color to express destructive actions.
      textButtonTheme: TextButtonThemeData(
        style: ButtonStyle(
          minimumSize: const WidgetStatePropertyAll(buttonMinimumSize),
          padding: const WidgetStatePropertyAll(buttonPadding),
          shape: WidgetStatePropertyAll(buttonShape),
          textStyle: WidgetStatePropertyAll(buttonText),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: ButtonStyle(
          minimumSize: const WidgetStatePropertyAll(buttonMinimumSize),
          padding: const WidgetStatePropertyAll(buttonPadding),
          shape: WidgetStatePropertyAll(buttonShape),
          textStyle: WidgetStatePropertyAll(buttonText),
        ),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: ButtonStyle(
          minimumSize: const WidgetStatePropertyAll(buttonMinimumSize),
          padding: const WidgetStatePropertyAll(buttonPadding),
          shape: WidgetStatePropertyAll(buttonShape),
          textStyle: WidgetStatePropertyAll(buttonText),
        ),
      ),
      iconButtonTheme: IconButtonThemeData(
        style: ButtonStyle(
          minimumSize: const WidgetStatePropertyAll(buttonMinimumSize),
          padding: const WidgetStatePropertyAll(EdgeInsets.all(8)),
          shape: WidgetStatePropertyAll(buttonShape),
        ),
      ),
      inputDecorationTheme: InputDecorationThemeData(
        filled: true,
        fillColor: colors.surfaceContainerLow,
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 12,
          vertical: 11,
        ),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: BorderSide(color: colors.outlineVariant),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: BorderSide(color: colors.outlineVariant),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: BorderSide(color: colors.primary, width: 1.5),
        ),
      ),
      popupMenuTheme: PopupMenuThemeData(
        color: colors.surfaceContainerHigh,
        surfaceTintColor: Colors.transparent,
        elevation: 12,
        menuPadding: const EdgeInsets.symmetric(vertical: 6),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        textStyle: textTheme.bodyMedium,
      ),
      menuTheme: MenuThemeData(
        style: MenuStyle(
          backgroundColor: WidgetStatePropertyAll(colors.surfaceContainerHigh),
          surfaceTintColor: const WidgetStatePropertyAll(Colors.transparent),
          elevation: const WidgetStatePropertyAll(12),
          shape: WidgetStatePropertyAll(
            RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
          ),
          padding: const WidgetStatePropertyAll(
            EdgeInsets.symmetric(vertical: 6),
          ),
        ),
      ),
    );
  }
}
