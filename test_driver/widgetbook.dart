/// Widgetbook with Flutter Driver's extension on, so an agent can open use
/// cases and take screenshots through the Dart MCP server. Run with
/// `make widgetbook_driver`; see AGENTS.md, "Testing with the Dart MCP server".
library;

import 'package:flutter_driver/driver_extension.dart';

import '../widgetbook/main.dart' as widgetbook;

void main() {
  // Off, so the real keyboard keeps working in the window. The driver's
  // `enter_text` needs it on: send `set_text_entry_emulation` first.
  enableFlutterDriverExtension(enableTextEntryEmulation: false);
  widgetbook.main();
}
