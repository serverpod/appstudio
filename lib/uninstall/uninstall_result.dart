import 'package:flutter/foundation.dart';

import '../toolchain/tool_status.dart';

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

/// What the user agreed to remove.
class UninstallChoice {
  const UninstallChoice({required this.tools});

  /// Tools App Studio installed that go too. App Studio's own data always
  /// goes; these are opt-out, because other things on the Mac may use them.
  final Set<ToolId> tools;

  /// `dart pub cache clean` runs exactly when Flutter goes: the cache is
  /// Flutter's Dart's, and with Flutter staying it is left alone.
  bool get clearPubCache => tools.contains(ToolId.flutter);
}
