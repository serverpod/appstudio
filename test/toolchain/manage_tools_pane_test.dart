import 'package:appstudio/theme/app_theme.dart';
import 'package:appstudio/toolchain/tool_status.dart';
import 'package:appstudio/toolchain/tool_version.dart';
import 'package:appstudio/toolchain/toolchain.dart';
import 'package:appstudio/toolchain/toolchain_controller.dart';
import 'package:appstudio/toolchain/toolchain_manifest.dart';
import 'package:appstudio/toolchain/toolchain_paths.dart';
import 'package:appstudio/toolchain/toolchain_requirements.dart';
import 'package:appstudio/ui/toolchain/manage_tools_pane.dart';
import 'package:appstudio/ui/toolchain/tool_row.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shad/shad.dart';

import '../support/toolchain_support.dart';

late ToolManifest manifest;

ToolCandidate satisfied(ToolId id, ToolSource source, String version) =>
    ToolCandidate(
      id: id,
      source: source,
      fitness: ToolFitness.satisfied,
      root: '/tmp/$id',
      executable: '/tmp/$id/bin/${id.manifestId}',
      detectedVersion: ToolVersion.tryParse(version),
    );

ToolCandidate rejected(ToolId id, String version, String reason) =>
    ToolCandidate(
      id: id,
      source: ToolSource.host,
      fitness: ToolFitness.wrongVersion,
      root: '/usr/local',
      executable: '/usr/local/bin/${id.manifestId}',
      detectedVersion: ToolVersion.tryParse(version),
      reason: reason,
    );

/// A controller whose inventory is fixed, so the dialog is tested against
/// known state rather than whatever is installed on the machine.
ToolchainController controllerWith(Map<ToolId, List<ToolCandidate>> byTool) {
  final tools = {
    for (final entry in byTool.entries)
      entry.key: ToolStatus(
        spec: manifest[entry.key]!,
        candidates: entry.value,
      ),
  };
  return _FixedToolchainController(
    initial: Toolchain(
      ToolchainInventory(manifest: manifest, tools: tools),
    ),
    manifest: manifest,
    paths: ToolchainPaths.resolve(),
    requirements: ToolchainRequirements.empty,
  );
}

/// Refresh would re-probe the real machine and overwrite the fixture.
class _FixedToolchainController extends ToolchainController {
  _FixedToolchainController({
    required super.initial,
    required super.manifest,
    required super.paths,
    required super.requirements,
  });

  @override
  Future<void> refresh({bool deep = false}) async {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    manifest = await loadTestManifest();
  });

  Future<void> pumpPane(
    WidgetTester tester,
    ToolchainController toolchains,
  ) async {
    await tester.pumpWidget(
      ShadApp(
        theme: buildLightTheme(),
        home: Scaffold(body: ManageToolsPane(toolchains: toolchains)),
      ),
    );
    await tester.pump();
  }

  testWidgets('shows a row per tool with its source', (tester) async {
    await pumpPane(
      tester,
      controllerWith({
        ToolId.flutter: [
          satisfied(ToolId.flutter, ToolSource.managed, '3.44.2'),
        ],
        ToolId.git: [satisfied(ToolId.git, ToolSource.host, '2.53.0')],
      }),
    );

    expect(find.byType(ToolRow), findsNWidgets(2));
    expect(find.text('Flutter SDK'), findsOneWidget);
    expect(find.text('Managed'), findsOneWidget);
    expect(find.text('Host'), findsOneWidget);
    expect(find.text('Ready'), findsNWidgets(2));
  });

  testWidgets('a too-old host tool reads as an update, not a failure',
      (tester) async {
    await pumpPane(
      tester,
      controllerWith({
        ToolId.serverpodCli: [
          rejected(
            ToolId.serverpodCli,
            '3.5.0-beta.7',
            '3.5.0-beta.7 (needs >=4.0.0-beta.1 <4.1.0)',
          ),
        ],
      }),
    );

    expect(find.text('Update needed'), findsOneWidget);
    expect(
      find.textContaining('3.5.0-beta.7 (needs >=4.0.0-beta.1 <4.1.0)'),
      findsOneWidget,
    );
    // The requirement is stated even when nothing qualifies.
    expect(
      find.textContaining('Requires >=4.0.0-beta.1 <4.1.0'),
      findsOneWidget,
    );
  });

  testWidgets('warns once per missing required tool', (tester) async {
    await pumpPane(
      tester,
      controllerWith({
        ToolId.opencode: [
          const ToolCandidate.notFound(ToolId.opencode, ToolSource.managed),
        ],
      }),
    );

    expect(find.text('Not installed'), findsOneWidget);
    expect(
      find.textContaining('OpenCode is missing'),
      findsOneWidget,
    );
  });

  testWidgets('a complete toolchain shows no warning banner', (tester) async {
    await pumpPane(
      tester,
      controllerWith({
        for (final id in ToolId.values)
          id: [satisfied(id, ToolSource.managed, '1.0.0')],
      }),
    );

    expect(find.textContaining('missing'), findsNothing);
    expect(find.byType(ToolRow), findsNWidgets(ToolId.values.length));
  });

  testWidgets('no longer offers "Uninstall all tools"', (tester) async {
    // It moved to the App Studio menu and became a full uninstall — settings
    // and shell PATH included — so a tools-scoped button here would understate
    // what it does.
    await pumpPane(
      tester,
      controllerWith({
        ToolId.flutter: [
          satisfied(ToolId.flutter, ToolSource.managed, '3.44.2'),
        ],
      }),
    );

    expect(find.text('Uninstall all tools'), findsNothing);
  });
}
