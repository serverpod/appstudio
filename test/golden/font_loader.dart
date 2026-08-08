import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// Loads the real macOS UI font into the test binding.
///
/// Without this, `flutter_test` renders every glyph as an Ahem box, which
/// makes a golden useless for reviewing *copy* — you can see the layout but
/// not a single word. App Studio ships only on macOS and uses the system font,
/// so the system font file is the honest thing to render with.
///
/// Skipped silently where the file is absent (a Linux CI box), in which case
/// goldens fall back to boxes and still catch layout changes.
Future<void> loadSystemFonts() async {
  await _load('.AppleSystemUIFont', '/System/Library/Fonts/SFNS.ttf');
  // The terminal and any monospace UI.
  await _load('Menlo', '/System/Library/Fonts/SFNSMono.ttf');
}

Future<void> _load(String family, String path) async {
  final file = File(path);
  if (!file.existsSync()) return;
  final bytes = await file.readAsBytes();
  final loader = FontLoader(family)
    ..addFont(Future.value(ByteData.sublistView(bytes)));
  await loader.load();
}
