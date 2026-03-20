import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

/// CS2 rarity colors — used throughout the app for item borders,
/// badges, and accent highlights.
class CS2Colors {
  static const consumerGrade = Color(0xFFB0C3D9);
  static const industrialGrade = Color(0xFF5E98D9);
  static const milSpec = Color(0xFF4B69FF);
  static const restricted = Color(0xFF8847FF);
  static const classified = Color(0xFFD32CE6);
  static const covert = Color(0xFFEB4B4B);
  static const extraordinary = Color(0xFFFFD700); // ★ Knives, Gloves

  /// Look up a Color from a rarity name string.
  static Color fromRarity(String rarity) {
    return switch (rarity.toLowerCase()) {
      'consumer grade' || 'consumer' => consumerGrade,
      'industrial grade' || 'industrial' => industrialGrade,
      'mil-spec' || 'mil-spec grade' => milSpec,
      'restricted' => restricted,
      'classified' => classified,
      'covert' => covert,
      'extraordinary' || 'contraband' => extraordinary,
      _ => consumerGrade,
    };
  }
}

class AppTheme {
  static ThemeData get dark {
    return ThemeData(
      brightness: Brightness.dark,
      useMaterial3: true,
      colorScheme: ColorScheme.dark(
        primary: CS2Colors.milSpec,
        secondary: CS2Colors.classified,
        surface: const Color(0xFF1A1A2E),
        // Slightly lighter surface for cards
        surfaceContainerHighest: const Color(0xFF25253E),
      ),
      scaffoldBackgroundColor: const Color(0xFF0F0F1A),
      textTheme: GoogleFonts.interTextTheme(ThemeData.dark().textTheme),
      cardTheme: CardThemeData(
        color: const Color(0xFF1A1A2E),
        elevation: 2,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      ),
      appBarTheme: const AppBarTheme(
        backgroundColor: Color(0xFF0F0F1A),
        elevation: 0,
        centerTitle: false,
      ),
    );
  }
}
