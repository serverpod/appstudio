/// App Studio with Flutter Driver's extension on, so an agent can drive it
/// through the Dart MCP server — tap, type, take screenshots. Run with
/// `make start_driver`; see AGENTS.md, "Testing with the Dart MCP server".
///
/// Outside `lib/` on purpose: `flutter_driver` is a dev dependency and must
/// never reach a release build.
library;

import 'package:appstudio/main.dart' as app;
import 'package:flutter_driver/driver_extension.dart';

Future<void> main() async {
  // Off, so the real keyboard keeps working in the window. The driver's
  // `enter_text` needs it on: send `set_text_entry_emulation` first.
  enableFlutterDriverExtension(enableTextEntryEmulation: false);
  await app.main();
}
