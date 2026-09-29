import 'dart:io';

import 'package:appstudio/toolchain/tool_probe.dart';
import 'package:appstudio/toolchain/tool_status.dart';
import 'package:appstudio/toolchain/toolchain.dart';
import 'package:appstudio/toolchain/toolchain_controller.dart';
import 'package:appstudio/toolchain/toolchain_manifest.dart';
import 'package:appstudio/toolchain/toolchain_paths.dart';

Future<String> loadTestManifestSource() =>
    File('assets/toolchain_manifest.json').readAsString();

Future<ToolManifest> loadTestManifest() async =>
    ToolManifest.tryParse(await loadTestManifestSource())!;

/// A controller with nothing resolved. Instant, and correct for tests that only
/// need a controller to exist — it never spawns a tool, even when re-probed.
///
/// [paths] defaults to the real home: nothing here writes to it unless a test
/// installs or uninstalls, and those pass a scratch one.
Future<ToolchainController> emptyToolchainController({
  ToolchainPaths? paths,
}) async {
  final manifest = await loadTestManifest();
  return ToolchainController(
    initial: Toolchain(
      ToolchainInventory(manifest: manifest, tools: const {}),
    ),
    manifest: manifest,
    paths: paths ?? ToolchainPaths.resolve(),
    // A re-probe must never run the real tools — see [ProbeSandbox].
    probeSandbox: ProbeSandbox.empty,
  );
}

/// A controller that has actually probed this machine. Slower (~350 ms) — use
/// only where resolution itself is under test.
Future<ToolchainController> probedToolchainController() async {
  final manifest = await loadTestManifest();
  final paths = ToolchainPaths.resolve();
  return ToolchainController(
    initial: await Toolchain.resolve(manifest: manifest, paths: paths),
    manifest: manifest,
    paths: paths,
  );
}
