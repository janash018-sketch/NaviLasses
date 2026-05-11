import 'package:flutter/material.dart';

class AppColors {
  // ── Backgrounds ───────────────────────────────────────────────────────────
  static const Color bgPrimary  = Color(0xFF0D0B14);
  static const Color bgCard     = Color(0xFF1C1728);
  static const Color bgCardAlt  = Color(0xFF241E38);

  // ── Card gradients ────────────────────────────────────────────────────────
  static const LinearGradient gradNav = LinearGradient(
    colors: [Color(0xFF6B48FF), Color(0xFFC650FF)],
    begin: Alignment.topLeft, end: Alignment.bottomRight,
  );
  static const LinearGradient gradBill = LinearGradient(
    colors: [Color(0xFFFF8C00), Color(0xFFFFD200)],
    begin: Alignment.topLeft, end: Alignment.bottomRight,
  );
  static const LinearGradient gradObstacle = LinearGradient(
    colors: [Color(0xFF0DD2C8), Color(0xFF86EFAC)],
    begin: Alignment.topLeft, end: Alignment.bottomRight,
  );
  static const LinearGradient gradTraffic = LinearGradient(
    colors: [Color(0xFFFF5CAA), Color(0xFFC066FF)],
    begin: Alignment.topLeft, end: Alignment.bottomRight,
  );
  static const LinearGradient gradOcr = LinearGradient(
    colors: [Color(0xFF4776E6), Color(0xFF8E54E9)],
    begin: Alignment.topLeft, end: Alignment.bottomRight,
  );
  static const LinearGradient gradVision = LinearGradient(
    colors: [Color(0xFFF7971E), Color(0xFFFFD200)],
    begin: Alignment.topLeft, end: Alignment.bottomRight,
  );

  // ── Accent colours (used in sub-screens for status indicators) ────────────
  static const Color accentYellow = Color(0xFFFBBF24);
  static const Color accentGreen  = Color(0xFF2DD4BF);
  static const Color accentRed    = Color(0xFFEF4444);
  static const Color accentBlue   = Color(0xFF818CF8);
  static const Color accentOrange = Color(0xFFF97316);
  static const Color accentPurple = Color(0xFF8B5CF6);

  // ── Text ──────────────────────────────────────────────────────────────────
  static const Color textPrimary   = Color(0xFFFFFFFF);
  static const Color textSecondary = Color(0xFF9B8EC4);
  static const Color textDark      = Color(0xFF0D0B14);
  static const Color textLight     = Color(0xFFFFFFFF);

  // ── Legacy tile aliases (kept so sub-screens compile without changes) ─────
  static const Color tileBlue    = Color(0xFF1E1B38);
  static const Color tileMint    = Color(0xFF1B2E2C);
  static const Color tilePurple  = Color(0xFF231B38);
  static const Color tilePink    = Color(0xFF2E1B28);
  static const Color tileYellow  = Color(0xFF2E2514);
  static const Color tileOrange  = Color(0xFF2E2018);
}

class AppTextStyles {
  static const TextStyle displayLarge = TextStyle(
    fontSize: 42,
    fontWeight: FontWeight.w900,
    color: AppColors.textPrimary,
    letterSpacing: -1.5,
    height: 1.05,
  );

  static const TextStyle displayMedium = TextStyle(
    fontSize: 30,
    fontWeight: FontWeight.w800,
    color: AppColors.textPrimary,
    letterSpacing: -0.8,
    height: 1.1,
  );

  static const TextStyle headingLarge = TextStyle(
    fontSize: 22,
    fontWeight: FontWeight.w700,
    color: AppColors.textPrimary,
  );

  static const TextStyle headingMedium = TextStyle(
    fontSize: 18,
    fontWeight: FontWeight.w700,
    color: AppColors.textPrimary,
  );

  static const TextStyle bodyLarge = TextStyle(
    fontSize: 16,
    fontWeight: FontWeight.w500,
    color: AppColors.textPrimary,
  );

  static const TextStyle bodySecondary = TextStyle(
    fontSize: 14,
    fontWeight: FontWeight.w400,
    color: AppColors.textSecondary,
    height: 1.5,
  );

  static const TextStyle labelBold = TextStyle(
    fontSize: 12,
    fontWeight: FontWeight.w700,
    letterSpacing: 0.5,
    color: AppColors.textPrimary,
  );

  static const TextStyle cardCategory = TextStyle(
    fontSize: 17,
    fontWeight: FontWeight.w900,
    color: AppColors.textPrimary,
    letterSpacing: -0.3,
    height: 1.2,
  );

  static const TextStyle cardSubtitle = TextStyle(
    fontSize: 12,
    fontWeight: FontWeight.w500,
    color: AppColors.textPrimary,
    letterSpacing: 0.1,
  );
}

class AppTheme {
  static ThemeData get darkTheme {
    return ThemeData(
      brightness: Brightness.dark,
      scaffoldBackgroundColor: AppColors.bgPrimary,
      useMaterial3: true,
      colorScheme: const ColorScheme.dark(
        primary: AppColors.accentPurple,
        surface: AppColors.bgCard,
        onPrimary: AppColors.textLight,
        onSurface: AppColors.textPrimary,
      ),
      appBarTheme: const AppBarTheme(
        backgroundColor: Colors.transparent,
        elevation: 0,
        iconTheme: IconThemeData(color: AppColors.textPrimary),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: AppColors.bgCard,
        hintStyle: const TextStyle(color: AppColors.textSecondary),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(16),
          borderSide: BorderSide.none,
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(16),
          borderSide: BorderSide.none,
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(16),
          borderSide: const BorderSide(color: AppColors.accentPurple, width: 1.5),
        ),
      ),
    );
  }

  // Keep alias for backwards compat
  static ThemeData get lightTheme => darkTheme;
}
