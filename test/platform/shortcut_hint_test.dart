import 'package:appstudio/platform/shortcut_hint.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

/// Tooltips name a shortcut the way the platform's menus bind it.
void main() {
  tearDown(() => debugDefaultTargetPlatformOverride = null);

  test('macOS writes ⌘ and ⇧', () {
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    expect(shortcutHint('R'), '⌘R');
    expect(shortcutHint('R', shift: true), '⇧⌘R');
  });

  test('Windows and Linux write Ctrl, as their menu strip binds it', () {
    for (final platform in [TargetPlatform.windows, TargetPlatform.linux]) {
      debugDefaultTargetPlatformOverride = platform;
      expect(shortcutHint('R'), 'Ctrl+R', reason: '$platform');
      expect(shortcutHint('R', shift: true), 'Ctrl+Shift+R',
          reason: '$platform');
    }
  });
}
