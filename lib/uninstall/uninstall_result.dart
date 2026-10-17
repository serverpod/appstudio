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

/// The step App Studio cannot do for itself: removing the app. On Windows the
/// installer's own uninstaller does that.
bool get _windows => defaultTargetPlatform == TargetPlatform.windows;

/// "Afterward, you can …" in the confirm dialog.
String get removeAppAfterward => _windows
    ? 'remove the app itself from Settings → Apps → Installed apps'
    : 'drag the app itself to the Trash';

/// "You can now safely …" on the screen that follows.
String get removeAppNow => _windows
    ? 'uninstall App Studio from Settings → Apps → Installed apps'
    : 'move App Studio to the Trash';

/// Tools the dialog offers unticked: settings other software may rely on,
/// rather than something App Studio alone uses.
const kUninstallUntickedByDefault = {ToolId.developerMode};

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
