import 'package:appstudio/toolchain/tool_status.dart';
import 'package:appstudio/toolchain/toolchain_manifest.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/toolchain_support.dart';

/// The condition that decides which screen `main.dart` shows, which App menu
/// items are live, and whether `StudioShell` will open Settings at all.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late ToolManifest manifest;

  setUpAll(() async {
    manifest = await loadTestManifest();
  });

  ToolchainInventory inventoryOf(
    Map<ToolId, ToolAction> actions, {
    bool legacy = false,
  }) =>
      ToolchainInventory(
        manifest: manifest,
        legacyInstallFound: legacy,
        tools: {
          for (final e in actions.entries)
            e.key: ToolStatus(
              spec: manifest[e.key]!,
              candidates: const [],
              action: e.value,
            ),
        },
      );

  test('a tool App Studio can install puts first-run setup on screen', () {
    final inventory = inventoryOf({ToolId.flutter: ToolAction.install});

    expect(inventory.installable, isNotEmpty);
    expect(inventory.needsSetup, isTrue);
  });

  test('so does a Flutter the user has to update themselves', () {
    // Setup is where they are asked to — and the Serverpod CLI is installed
    // with that Flutter's dart, so nothing else can go ahead first.
    final inventory = inventoryOf({ToolId.flutter: ToolAction.manual});

    expect(inventory.installable, isEmpty);
    expect(inventory.needsManualUpdate, hasLength(1));
    expect(inventory.needsSetup, isTrue);
  });

  test('so does a toolchain an earlier build left behind', () {
    // Even with every tool already usable: the old copies and their PATH block
    // still have to go, and the user has to be told why.
    expect(inventoryOf(const {}, legacy: true).needsSetup, isTrue);
  });

  test('a complete toolchain does not', () {
    expect(inventoryOf(const {}).needsSetup, isFalse);
  });

  test('installable is in install order, whatever order the map is in', () {
    // The Command Line Tools supply Flutter's git, and Flutter supplies the
    // dart the Serverpod CLI is installed with.
    final inventory = inventoryOf({
      ToolId.serverpodCli: ToolAction.install,
      ToolId.flutter: ToolAction.update,
      ToolId.commandLineTools: ToolAction.install,
    });

    expect(
      [for (final t in inventory.installable) t.id],
      [ToolId.commandLineTools, ToolId.flutter, ToolId.serverpodCli],
    );
  });
}
