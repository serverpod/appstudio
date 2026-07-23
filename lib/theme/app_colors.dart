import 'package:flutter/material.dart';

/// Custom semantic color tokens used throughout App Studio.
///
/// Neutral/surface colors are intentionally omitted here — use
/// [ShadTheme.of(context).colorScheme] for those so they adapt to theme changes.
abstract final class AppColors {
  // Success — running / ready status
  static const Color successDot = Color(0xFF22C55E);
  static const Color successText = Color(0xFF15803D);
  static const Color successTextDark = Color(0xFF86EFAC);

  // Warning — starting / stopping status
  static const Color warningAmber = Color(0xFFF59E0B);
  static const Color warningText = Color(0xFFB45309);
  static const Color warningTextDark = Color(0xFFF59E0B);

  // Error — failures
  static const Color errorRed = Color(0xFFEF4444);
  static const Color errorText = Color(0xFFB91C1C);
  static const Color errorTextDark = Color(0xFFFCA5A5);
}
