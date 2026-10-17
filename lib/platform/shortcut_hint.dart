import 'package:flutter/foundation.dart';

/// A keyboard shortcut as the platform writes it in a tooltip: `⇧⌘R` on a
/// Mac, `Ctrl+Shift+R` on Windows — where the Windows menu strip binds the
/// same keys with Ctrl (`platform/windows_app_menu.dart`).
String shortcutHint(String key, {bool shift = false}) =>
    defaultTargetPlatform == TargetPlatform.windows
        ? 'Ctrl+${shift ? 'Shift+' : ''}$key'
        : '${shift ? '⇧' : ''}⌘$key';
