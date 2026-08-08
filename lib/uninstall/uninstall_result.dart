import 'package:flutter/foundation.dart';

/// What a full uninstall removed, for the confirmation screen.
///
/// Kept apart from [Uninstaller] so the screen that renders it does not import
/// `dart:io`. `UninstalledScreen` is pure presentation and belongs in widget
/// previews; sitting next to `Directory.delete` would have
/// made that impossible.
@immutable
class UninstallResult {
  const UninstallResult({required this.failures});

  /// Steps that did not complete. The uninstall never aborts on one of these:
  /// stopping halfway would leave the user with neither a working install nor
  /// a clean machine, and no way to tell which.
  final List<String> failures;

  bool get isClean => failures.isEmpty;
}
