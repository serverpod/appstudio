import 'dart:io';

import 'package:appstudio/toolchain/tool_status.dart';
import 'package:appstudio/toolchain/toolchain.dart';
import 'package:appstudio/toolchain/toolchain_controller.dart';
import 'package:appstudio/toolchain/toolchain_manifest.dart';
import 'package:appstudio/toolchain/toolchain_paths.dart';
import 'package:appstudio/toolchain/toolchain_requirements.dart';

Future<ToolManifest> loadTestManifest() async {
  final source = await File('assets/toolchain_manifest.json').readAsString();
  return ToolManifest.tryParse(source)!;
}

/// A controller with nothing resolved. Instant, and correct for tests that only
/// need a controller to exist — they never spawn a tool.
Future<ToolchainController> emptyToolchainController() async {
  final manifest = await loadTestManifest();
  return ToolchainController(
    initial: Toolchain(
      ToolchainInventory(manifest: manifest, tools: const {}),
    ),
    manifest: manifest,
    paths: ToolchainPaths.resolve(),
    requirements: ToolchainRequirements.empty,
  );
}

/// A controller that has actually probed this machine. Slower (~350 ms) — use
/// only where resolution itself is under test.
Future<ToolchainController> probedToolchainController() async {
  final manifest = await loadTestManifest();
  final paths = ToolchainPaths.resolve();
  return ToolchainController(
    initial: await Toolchain.resolve(
      manifest: manifest,
      requirements: ToolchainRequirements.empty,
      paths: paths,
    ),
    manifest: manifest,
    paths: paths,
    requirements: ToolchainRequirements.empty,
  );
}
