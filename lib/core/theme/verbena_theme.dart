import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

/// Paleta y tipografía tal cual el handoff de diseño (Verbena App.dc.html,
/// variante Home C). No introducir tonos nuevos sin volver al handoff.
abstract final class VerbenaColors {
  static const background = Color(0xFFF3E6D0);
  static const teal = Color(0xFF3D5C52);
  static const terracotta = Color(0xFF8A3324);
  static const textDark = Color(0xFF2B2118);
  static const textMuted = Color(0xFF5A4E40);
  static const card = Color(0xFFFBF3E4);
  static const whatsappGreen = Color(0xFF25D366);
}

abstract final class VerbenaText {
  /// Anton — títulos y botones, normalmente en mayúsculas con letter-spacing.
  static TextStyle display({
    double size = 22,
    Color color = VerbenaColors.textDark,
    double letterSpacing = 0.5,
  }) =>
      GoogleFonts.anton(fontSize: size, color: color, letterSpacing: letterSpacing);

  /// Work Sans — cuerpo de texto.
  static TextStyle body({
    double size = 15,
    Color color = VerbenaColors.textDark,
    FontWeight weight = FontWeight.w400,
  }) =>
      GoogleFonts.workSans(fontSize: size, color: color, fontWeight: weight);
}

ThemeData buildVerbenaTheme() {
  final base = ThemeData(useMaterial3: true, brightness: Brightness.light);
  return base.copyWith(
    scaffoldBackgroundColor: VerbenaColors.background,
    colorScheme: base.colorScheme.copyWith(
      primary: VerbenaColors.teal,
      secondary: VerbenaColors.terracotta,
      surface: VerbenaColors.background,
    ),
    textTheme: GoogleFonts.workSansTextTheme(base.textTheme).apply(
      bodyColor: VerbenaColors.textDark,
      displayColor: VerbenaColors.textDark,
    ),
    elevatedButtonTheme: ElevatedButtonThemeData(
      style: ElevatedButton.styleFrom(
        backgroundColor: VerbenaColors.teal,
        foregroundColor: VerbenaColors.background,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        padding: const EdgeInsets.symmetric(vertical: 17),
        textStyle: VerbenaText.display(size: 17, color: VerbenaColors.background),
      ),
    ),
  );
}
