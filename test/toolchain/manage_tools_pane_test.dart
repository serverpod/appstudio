import 'package:appstudio/theme/app_theme.dart';
import 'package:appstudio/toolchain/shell_path_state.dart';
import 'package:appstudio/toolchain/tool_status.dart';
import 'package:appstudio/toolchain/tool_version.dart';
import 'package:appstudio/toolchain/toolchain.dart';
import 'package:appstudio/toolchain/toolchain_controller.dart';
import 'package:appstudio/toolchain/toolchain_manifest.dart';
import 'package:appstudio/toolchain/toolchain_paths.dart';
import 'package:appstudio/toolchain/toolchain_requirements.dart';
import 'package:appstudio/ui/toolchain/manage_tools_pane.dart';
import 'package:appstudio/widgets/error_banner.dart';
import 'package:appstudio/widgets/settings_table.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shad/shad.dart';

import '../support/toolchain_support.dart';

late ToolManifest manifest;

/// The version the live manifest pins for Flutter, so "current" fixtures track
/// a Flutter bump instead of silently turning into behind-the-pin ones.
String pinFor(ToolId id) => manifest[id]!.version.toString();

String flutterPin() => pinFor(ToolId.flutter);

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

/// A controller whose inventory is fixed, so the pane is tested against known
/// state rather than whatever is installed on the machine.
// ignore: library_private_types_in_public_api
_FixedToolchainController controllerWith(
  Map<ToolId, List<ToolCandidate>> byTool, {
  ShellPathState shellPathState = ShellPathState.absent,
}) {
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
    shellPathState: shellPathState,
  );
}

/// Refresh would re-probe the real machine and overwrite the fixture; preflight
/// would go to the network; the shell PATH calls would edit the rc file of
/// whoever is running the tests.
class _FixedToolchainController extends ToolchainController {
  _FixedToolchainController({
    required super.initial,
    required super.manifest,
    required super.paths,
    required super.requirements,
    ShellPathState shellPathState = ShellPathState.absent,
  }) : _state = shellPathState;

  ShellPathState _state;

  /// What the pane asked us to write, in order.
  final List<bool> shellPathWrites = [];

  @override
  ShellPathState get shellPathState => _state;

  @override
  Future<void> refresh({bool deep = false}) async {}

  @override
  Future<String?> preflight() async => null;

  @override
  Future<void> refreshShellPathState() async {}

  @override
  Future<String?> setShellPathEnabled(bool enabled, {bool force = false}) async {
    shellPathWrites.add(enabled);
    _state = enabled ? ShellPathState.present : ShellPathState.absent;
    notifyListeners();
    return null;
  }
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

  testWidgets('lists every tool with its version and where it came from',
      (tester) async {
    await pumpPane(
      tester,
      controllerWith({
        ToolId.flutter: [
          satisfied(ToolId.flutter, ToolSource.managed, flutterPin()),
        ],
        ToolId.git: [satisfied(ToolId.git, ToolSource.host, '2.53.0')],
      }),
    );

    expect(find.byType(SettingsTable), findsOneWidget);
    expect(find.text('Flutter SDK'), findsOneWidget);
    expect(find.text(flutterPin()), findsOneWidget);
    expect(find.text('2.53.0'), findsOneWidget);
    // A host copy reads as "Native" now — "On your Mac" was a sentence where a
    // badge belongs.
    expect(find.text('Managed'), findsOneWidget);
    expect(find.text('Native'), findsOneWidget);
    expect(find.text('On your Mac'), findsNothing);
  });

  testWidgets('a tool with nothing usable gets a Missing badge',
      (tester) async {
    await pumpPane(
      tester,
      controllerWith({
        ToolId.opencode: [
          const ToolCandidate.notFound(ToolId.opencode, ToolSource.managed),
        ],
      }),
    );

    expect(find.text('Missing'), findsOneWidget);
    expect(find.textContaining('OpenCode is missing'), findsOneWidget);
  });

  testWidgets('a too-old host copy shows what would replace it',
      (tester) async {
    await pumpPane(
      tester,
      controllerWith({
        ToolId.serverpodCli: [
          rejected(ToolId.serverpodCli, '3.5.0-beta.7', 'too old'),
        ],
      }),
    );

    // The version that is there, then the one that would land — otherwise a
    // working `serverpod` command beside a plain "Missing" reads as a failed
    // detection rather than an upgrade.
    expect(
      find.text('3.5.0-beta.7 → ${pinFor(ToolId.serverpodCli)}'),
      findsOneWidget,
    );
    expect(find.text('Missing'), findsOneWidget);
  });

  testWidgets('Update All is disabled when everything is current',
      (tester) async {
    await pumpPane(
      tester,
      controllerWith({
        ToolId.flutter: [
          satisfied(ToolId.flutter, ToolSource.managed, flutterPin()),
        ],
      }),
    );

    final button = tester.widget<ShadButton>(
      find.widgetWithText(ShadButton, 'Update All'),
    );
    // Disabled rather than hidden: "is there anything newer?" is a question the
    // tab should answer even when the answer is no.
    expect(button.onPressed, isNull);
    // And `enabled`, which is what shad actually dims on — a null onPressed
    // alone leaves it looking live.
    expect(button.enabled, isFalse);
  });

  testWidgets('Update All lights up for a managed install behind the pin',
      (tester) async {
    await pumpPane(
      tester,
      controllerWith({
        ToolId.flutter: [
          satisfied(ToolId.flutter, ToolSource.managed, '3.44.0'),
        ],
      }),
    );

    final button = tester.widget<ShadButton>(
      find.widgetWithText(ShadButton, 'Update All'),
    );
    expect(button.onPressed, isNotNull);
    expect(button.enabled, isTrue);
    // The row states the move rather than just the installed version.
    expect(find.text('3.44.0 → ${flutterPin()}'), findsOneWidget);
  });

  testWidgets('a host copy behind our pin is not ours to update',
      (tester) async {
    // We did not install it and must not overwrite it.
    await pumpPane(
      tester,
      controllerWith({
        ToolId.git: [satisfied(ToolId.git, ToolSource.host, '2.30.0')],
      }),
    );

    final button = tester.widget<ShadButton>(
      find.widgetWithText(ShadButton, 'Update All'),
    );
    expect(button.enabled, isFalse);
    expect(find.text('2.30.0'), findsOneWidget);
  });

  testWidgets('puts the tools on PATH without asking', (tester) async {
    // The opt-in is gone: an external editor or AI agent is the only thing that
    // reaches the toolchain from outside now, so the pane makes it true rather
    // than offering it.
    final tools = controllerWith({
      ToolId.flutter: [
        satisfied(ToolId.flutter, ToolSource.managed, flutterPin()),
      ],
    });
    await pumpPane(tester, tools);
    await tester.pump();

    expect(find.byType(ShadCheckbox), findsNothing);
    expect(find.text('Install tools globally'), findsNothing);
    expect(tools.shellPathWrites, [true]);
  });

  testWidgets('writes nothing when there is nothing to add', (tester) async {
    // Every required tool is already on this Mac, so our PATH block would add
    // nothing — and editing the user's shell config to no effect is worse than
    // leaving it alone.
    final tools = controllerWith({
      for (final id in ToolId.values)
        if (id != ToolId.opencode)
          id: [satisfied(id, ToolSource.host, '99.0.0')],
      // Managed, and deliberately not counted: OpenCode *is* the agent, so an
      // external one has no reason to look for it.
      ToolId.opencode: [
        satisfied(ToolId.opencode, ToolSource.managed, '1.18.4'),
      ],
    });
    await pumpPane(tester, tools);
    await tester.pump();

    expect(tools.shellPathWrites, isEmpty);
  });

  testWidgets('a block already in place is left alone', (tester) async {
    final tools = controllerWith(
      {
        ToolId.flutter: [
          satisfied(ToolId.flutter, ToolSource.managed, flutterPin()),
        ],
      },
      shellPathState: ShellPathState.present,
    );
    await pumpPane(tester, tools);
    await tester.pump();

    expect(tools.shellPathWrites, isEmpty);
    // Nothing to report, so the section draws nothing.
    expect(find.byType(ErrorBanner), findsNothing);
  });

  testWidgets('a hand-edited block is reported, not overwritten',
      (tester) async {
    final tools = controllerWith(
      {
        ToolId.flutter: [
          satisfied(ToolId.flutter, ToolSource.managed, flutterPin()),
        ],
      },
      shellPathState: ShellPathState.edited,
    );
    await pumpPane(tester, tools);
    await tester.pump();

    expect(tools.shellPathWrites, isEmpty);
    expect(find.byType(ErrorBanner), findsOneWidget);

    // Replacing is the only way out now: there is no opting back out of it.
    expect(find.text('Remove it'), findsNothing);
    await tester.tap(find.text('Replace (backs up first)'));
    await tester.pump();
    expect(tools.shellPathWrites, [true]);
  });

  testWidgets('a shell we cannot edit gets the line to add by hand',
      (tester) async {
    final tools = controllerWith(
      {
        ToolId.flutter: [
          satisfied(ToolId.flutter, ToolSource.managed, flutterPin()),
        ],
      },
      shellPathState: ShellPathState.unsupported,
    );
    await pumpPane(tester, tools);
    await tester.pump();

    expect(tools.shellPathWrites, isEmpty);
    expect(find.text('Install tools globally'), findsOneWidget);
    expect(find.textContaining('external AI agents'), findsOneWidget);
  });

  testWidgets('Developer tools, not "Native tools"', (tester) async {
    // The row would otherwise read "Native tools … Native", and these are the
    // Xcode command-line utilities by any other name.
    await pumpPane(
      tester,
      controllerWith({
        ToolId.llvmTools: [
          satisfied(ToolId.llvmTools, ToolSource.host, '21.0.0'),
        ],
      }),
    );

    expect(find.text('Developer tools'), findsOneWidget);
    expect(find.text('Native tools'), findsNothing);
  });

  testWidgets('drops the folder controls and the install path', (tester) async {
    await pumpPane(
      tester,
      controllerWith({
        ToolId.flutter: [
          satisfied(ToolId.flutter, ToolSource.managed, flutterPin()),
        ],
      }),
    );

    expect(find.text('Reveal'), findsNothing);
    expect(find.text('Re-check'), findsNothing);
    expect(find.textContaining('Application Support'), findsNothing);
  });

  testWidgets('renders with an inventory that could not be read',
      (tester) async {
    // `ToolchainController.create` falls back to an empty inventory when the
    // probe throws rather than refusing to launch, and ShadTable asserts on an
    // empty child list — so this pane has to survive it.
    await pumpPane(tester, controllerWith({}));

    expect(tester.takeException(), isNull);
    expect(find.byType(SettingsTable), findsOneWidget);
  });

  testWidgets('no longer offers "Uninstall all tools"', (tester) async {
    // It moved to the App Studio menu and became a full uninstall — settings
    // and shell PATH included — so a tools-scoped button here would understate
    // what it does.
    await pumpPane(
      tester,
      controllerWith({
        ToolId.flutter: [
          satisfied(ToolId.flutter, ToolSource.managed, flutterPin()),
        ],
      }),
    );

    expect(find.text('Uninstall all tools'), findsNothing);
  });
}
