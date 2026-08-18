import 'dart:convert';

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

  /// The same manifest with every download stripped from one tool — a required
  /// tool we have no artifact for, which is the case the setup screen cannot
  /// fix.
  Future<ToolManifest> manifestWithout(ToolId id) async {
    final json = jsonDecode(await loadTestManifestSource()) as Map<String, dynamic>;
    for (final tool in (json['tools'] as List).cast<Map<String, dynamic>>()) {
      if (tool['id'] == id.manifestId) tool['platforms'] = <String, dynamic>{};
    }
    return ToolManifest.tryParse(jsonEncode(json))!;
  }

  ToolchainInventory inventoryOf(ToolManifest m, List<ToolId> ids) =>
      ToolchainInventory(
        manifest: m,
        tools: {
          for (final id in ids)
            id: ToolStatus(spec: m[id]!, candidates: const []),
        },
      );

  test('a missing tool we can download puts first-run setup on screen', () {
    final inventory = inventoryOf(manifest, [ToolId.flutter]);

    expect(inventory.installable, isNotEmpty);
    expect(inventory.needsSetup, isTrue);
  });

  test('a complete toolchain does not', () async {
    expect(inventoryOf(manifest, const []).needsSetup, isFalse);
  });

  test('a missing tool we cannot download does not', () async {
    // The setup screen could do nothing about it, so blocking on it would be a
    // dead end — and it would take Settings → Tools, the one place that names
    // the problem, down with it.
    final stripped = await manifestWithout(ToolId.flutter);
    final inventory = inventoryOf(stripped, [ToolId.flutter]);

    expect(inventory.missingRequired, isNotEmpty);
    expect(inventory.needsSetup, isFalse);
  });
}
