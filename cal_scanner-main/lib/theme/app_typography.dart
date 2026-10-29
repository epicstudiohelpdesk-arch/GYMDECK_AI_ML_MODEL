import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:cal_scanner/theme/app_colors.dart';

class AppTypography {
  AppTypography._();

  // ───  SINGLE POINT OF CHANGE — swap font here only ──────
  static TextStyle _font({
    required double fontSize,
    required FontWeight fontWeight,
    double? letterSpacing,
    double? height,
    Color? color,
  }) => GoogleFonts.poppins(
    fontSize: fontSize,
    fontWeight: fontWeight,
    letterSpacing: letterSpacing,
    height: height,
    color: color ?? AppColors.kBlack,
  );

  // ─── Font Sizes ────────────────────────────────────────────
  static const double _xs = 10.0;
  static const double _sm = 12.0;
  static const double _md = 14.0;
  static const double _lg = 16.0;
  static const double _xl = 24.0;
  static const double _2xl = 22.0;
  static const double _3xl = 28.0;
  static const double _4xl = 36.0;
  static const double _5xl = 48.0;

  // ─── Display ───────────────────────────────────────────────
  static TextStyle get displayLarge => _font(
    fontSize: _5xl,
    fontWeight: FontWeight.w700,
    letterSpacing: -1.5,
    height: 1.1,
  );
  static TextStyle get displayMedium => _font(
    fontSize: _4xl,
    fontWeight: FontWeight.w700,
    letterSpacing: -1.0,
    height: 1.15,
  );
  static TextStyle get displaySmall => _font(
    fontSize: _3xl,
    fontWeight: FontWeight.w600,
    letterSpacing: -0.5,
    height: 1.2,
  );

  // ─── Headline ──────────────────────────────────────────────
  static TextStyle get headlineLarge => _font(
    fontSize: 30,
    fontWeight: FontWeight.w700,
    letterSpacing: -0.25,
    height: 1.3,
  );
  static TextStyle get headlineMedium => _font(
    fontSize: _xl,
    fontWeight: FontWeight.w600,
    letterSpacing: 0,
    height: 1.35,
  );
  static TextStyle get headlineSmall => _font(
    fontSize: _lg,
    fontWeight: FontWeight.w600,
    letterSpacing: 0,
    height: 1.4,
  );

  // ─── Title ─────────────────────────────────────────────────
  static TextStyle get titleLarge => _font(
    fontSize: _lg,
    fontWeight: FontWeight.w500,
    letterSpacing: 0.15,
    height: 1.4,
  );
  static TextStyle get titleMedium => _font(
    fontSize: _md,
    fontWeight: FontWeight.w500,
    letterSpacing: 0.1,
    height: 1.45,
  );
  static TextStyle get titleSmall => _font(
    fontSize: _sm,
    fontWeight: FontWeight.w500,
    letterSpacing: 0.1,
    height: 1.5,
  );

  // ─── Body ──────────────────────────────────────────────────
  static TextStyle get bodyLarge => _font(
    fontSize: _lg,
    fontWeight: FontWeight.w400,
    letterSpacing: 0.5,
    height: 1.6,
  );
  static TextStyle get bodyMedium => _font(
    fontSize: _md,
    fontWeight: FontWeight.w400,
    letterSpacing: 0.25,
    height: 1.6,
  );
  static TextStyle get bodySmall => _font(
    fontSize: _sm,
    fontWeight: FontWeight.w400,
    letterSpacing: 0.4,
    height: 1.55,
  );

  // ─── Label ───
  static TextStyle get labelLarge => _font(
    fontSize: _md,
    fontWeight: FontWeight.w700,
    letterSpacing: 0.1,
    height: 1.4,
  );
  static TextStyle get labelMedium => _font(
    fontSize: _sm,
    fontWeight: FontWeight.w700,
    letterSpacing: 0.5,
    height: 1.4,
  );
  static TextStyle get labelSmall => _font(
    fontSize: _xs,
    fontWeight: FontWeight.w700,
    letterSpacing: 0.5,
    height: 1.4,
  );

  // ─── TextTheme ─────────────────────────────────────────────
  static TextTheme get textTheme => TextTheme(
    displayLarge: displayLarge,
    displayMedium: displayMedium,
    displaySmall: displaySmall,
    headlineLarge: headlineLarge,
    headlineMedium: headlineMedium,
    headlineSmall: headlineSmall,
    titleLarge: titleLarge,
    titleMedium: titleMedium,
    titleSmall: titleSmall,
    bodyLarge: bodyLarge,
    bodyMedium: bodyMedium,
    bodySmall: bodySmall,
    labelLarge: labelLarge,
    labelMedium: labelMedium,
    labelSmall: labelSmall,
  );
}
