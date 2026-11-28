import 'dart:async';

import '../../widgetbook/fakes/tools.dart';
import 'package:appstudio/theme/app_theme.dart';
import 'package:appstudio/toolchain/tool_status.dart';
import 'package:appstudio/ui/toolchain/toolchain_notices.dart';
import 'package:appstudio/ui/toolchain/toolchain_setup_dialog.dart';
import 'package:appstudio/ui/toolchain/toolchain_setup_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shad/shad.dart';

import '../support/host_skips.dart';

/// A [ToolsView] whose preflight is answered by the test, one call at a time.
///
/// The real one goes to the network, and the whole point of the screen is what
/// it shows *while* that is outstanding.
class _ScriptedTools extends FakeToolsView {
  _ScriptedTools({super.inventory});

  final _pending = <Completer<String?>>[];
  int preflights = 0;

  @override
  Future<String?> preflight() {
    preflights++;
    final completer = Completer<String?>();
    _pending.add(completer);
    return completer.future;
  }

  /// Answers the preflight the screen is currently waiting on: null for a
  /// usable plan, a message for a failure.
  void answer(String? error) => _pending.removeAt(0).complete(error);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<void> pumpScreen(WidgetTester tester, FakeToolsView tools) async {
    await tester.pumpWidget(
      ShadApp(
        theme: buildLightTheme(),
        home: ToolchainSetupScreen(toolchains: tools),
      ),
    );
    // The preflight starts in a post-frame callback, so one pump is the moment
    // it is in flight and nothing has answered yet.
    await tester.pump();
  }

  /// Fixed pumps, never pumpAndSettle: ShadSpinner animates forever, so
  /// settling never completes on this screen.
  Future<void> settleDialog(WidgetTester tester) =>
      tester.pump(const Duration(milliseconds: 400));

  testWidgets('survives being centred in a loose parent', (tester) async {
    // LandingScaffold is a Column with an Expanded, so it needs a bounded
    // height — which a caller that centres it does not give it.
    final tools = _ScriptedTools(inventory: emptyInventory);
    await tester.pumpWidget(
      ShadApp(
        theme: buildLightTheme(),
        home: Scaffold(
          body: Center(child: ToolchainSetupScreen(toolchains: tools)),
        ),
      ),
    );
    await tester.pump();

    expect(tester.takeException(), isNull);
    expect(find.byType(ShadSpinner), findsOneWidget);
  });

  testWidgets('shows only a spinner until the plan has arrived', (tester) async {
    final tools = _ScriptedTools(inventory: emptyInventory);
    await pumpScreen(tester, tools);

    expect(find.byType(ShadSpinner), findsOneWidget);
    // The old behaviour raised the dialog immediately and filled the table in
    // afterwards, which read as a stuck dialog on a slow network.
    expect(find.byType(ToolchainSetupDialog), findsNothing);
    expect(tools.preflights, 1);
  });

  testWidgets('raises the download plan once the preflight succeeds',
      (tester) async {
    final tools = _ScriptedTools(inventory: emptyInventory);
    await pumpScreen(tester, tools);

    tools.answer(null);
    await settleDialog(tester);

    expect(find.byType(ToolchainSetupDialog), findsOneWidget);
    expect(find.text('Set up your tools'), findsOneWidget);
    // The plan is fully populated the moment it appears.
    expect(find.text('Flutter'), findsOneWidget);
    expect(find.text('Install'), findsOneWidget);
  });

  testWidgets('a failed preflight explains itself and retries on demand',
      (tester) async {
    final tools = _ScriptedTools(inventory: emptyInventory);
    await pumpScreen(tester, tools);

    tools.answer('Could not reach flutter.dev to look up the latest Flutter release.');
    await settleDialog(tester);

    expect(find.byType(ToolchainSetupErrorDialog), findsOneWidget);
    expect(
      find.text('Could not reach flutter.dev to look up the latest Flutter release.'),
      findsOneWidget,
    );
    // No plan is offered on the way past the failure — there is nothing to show.
    expect(find.byType(ToolchainSetupDialog), findsNothing);

    await tester.tap(find.text('Try again'));
    await settleDialog(tester);

    expect(tools.preflights, 2);
    expect(find.byType(ToolchainSetupErrorDialog), findsNothing);
    expect(find.byType(ShadSpinner), findsOneWidget);

    tools.answer(null);
    await settleDialog(tester);

    expect(find.byType(ToolchainSetupDialog), findsOneWidget);
  });

  testWidgets('the plan cannot be dismissed out from under the user',
      (tester) async {
    // Quit is the only way out. Popping it would leave a bare spinner with no
    // route back, since nothing downstream works without these tools.
    final tools = _ScriptedTools(inventory: emptyInventory);
    await pumpScreen(tester, tools);
    tools.answer(null);
    await settleDialog(tester);

    final navigator = tester.state<NavigatorState>(find.byType(Navigator));
    await navigator.maybePop();
    await settleDialog(tester);

    expect(find.byType(ToolchainSetupDialog), findsOneWidget);
  });

  testWidgets('no plan is raised when the preflight leaves nothing to install',
      (tester) async {
    // The user can install a tool in a terminal while the plan is being looked
    // up. The plan dialog only closes itself once an install has run, so an
    // empty one would sit there forever over the shell main.dart has switched
    // to.
    final tools = _ScriptedTools(inventory: emptyInventory);
    await pumpScreen(tester, tools);

    tools.inventory = completeInventory;
    tools.answer(null);
    await settleDialog(tester);

    expect(find.byType(ToolchainSetupDialog), findsNothing);
  });

  testWidgets('a complete toolchain never reaches the preflight',
      (tester) async {
    // main.dart gates on the same condition, so this is belt-and-braces: the
    // screen must not fire a network call it has no reason to make.
    final tools = _ScriptedTools(inventory: completeInventory);
    await pumpScreen(tester, tools);

    expect(tools.preflights, 0);
    expect(find.byType(ToolchainSetupDialog), findsNothing);
  });

  testWidgets('an earlier build\'s tools are explained, then removed, before '
      'anything is planned', (tester) async {
    final tools = _ScriptedTools(inventory: legacyInventory);
    await pumpScreen(tester, tools);
    await settleDialog(tester);

    expect(find.byType(LegacyInstallNotice), findsOneWidget);
    expect(tools.legacyRemovals, 0);
    expect(tools.preflights, 0);

    await tester.tap(find.text('Continue'));
    await settleDialog(tester);
    // A second pump for the route's exit transition.
    await settleDialog(tester);

    expect(tools.legacyRemovals, 1);
    expect(find.byType(LegacyInstallNotice), findsNothing);
    // With the old copies gone, setup carries on to the new install.
    expect(tools.preflights, 1);
  });

  testWidgets('with a Flutter already on the Mac, the old tools go without '
      'a notice', (tester) async {
    // The notice announces that App Studio stopped using its own Flutter. Here
    // it just uses the one the user has, so there is nothing to tell them.
    final tools = _ScriptedTools(inventory: legacyWithFlutterInventory);
    await pumpScreen(tester, tools);
    await settleDialog(tester);

    expect(find.byType(LegacyInstallNotice), findsNothing);
    expect(tools.legacyRemovals, 1);
    expect(tools.inventory.needsSetup, isFalse);
  });

  testWidgets('a Flutter the user must update blocks until they have',
      (tester) async {
    final tools = _ScriptedTools(inventory: manualUpdateInventory);
    await pumpScreen(tester, tools);
    await settleDialog(tester);

    expect(find.byType(ManualUpdateDialog), findsOneWidget);
    expect(find.text('~/flutter/bin/flutter upgrade'),
        findsOneWidget);
    expect(tools.preflights, 0);

    // Still old: the dialog stays, and says so.
    await tester.tap(find.text('Check again'));
    await settleDialog(tester);
    expect(find.byType(ManualUpdateDialog), findsOneWidget);
    expect(find.textContaining('Still out of date'), findsOneWidget);

    tools.inventory = completeInventory;
    await tester.tap(find.text('Check again'));
    await settleDialog(tester);
    await settleDialog(tester);

    expect(find.byType(ManualUpdateDialog), findsNothing);
  }, skip: macOSOnlyForNow); // Windows: Phase 3 (flutter.bat update command)

  testWidgets('missing Linux system packages block until they are installed',
      (tester) async {
    final tools = _ScriptedTools(inventory: linuxMissingPackagesInventory);
    await pumpScreen(tester, tools);
    await settleDialog(tester);

    expect(find.byType(ManualUpdateDialog), findsOneWidget);
    expect(find.text('Install system packages'), findsOneWidget);
    expect(find.textContaining('Flutter needs curl and xz'), findsOneWidget);
    expect(find.text('sudo apt install curl xz-utils'), findsOneWidget);
    // Nothing is looked up or installed before them: Flutter runs on them.
    expect(tools.preflights, 0);

    await tester.tap(find.text('Check again'));
    await settleDialog(tester);
    expect(find.textContaining('Still missing'), findsOneWidget);

    tools.inventory = completeInventory;
    await tester.tap(find.text('Check again'));
    await settleDialog(tester);
    await settleDialog(tester);

    expect(find.byType(ManualUpdateDialog), findsNothing);
  });

  testWidgets('an unknown distro gets the package names, not a command',
      (tester) async {
    final tools = _ScriptedTools(inventory: linuxUnknownDistroInventory);
    await pumpScreen(tester, tools);
    await settleDialog(tester);

    expect(
      find.textContaining("your distribution's package manager: curl, xz."),
      findsOneWidget,
    );
    expect(find.textContaining('sudo'), findsNothing);
  });

  test('the update command switches channel only when it has to', () {
    const candidate = ToolCandidate(
      id: ToolId.flutter,
      source: ToolSource.host,
      fitness: ToolFitness.wrongVersion,
      root: '/opt/flutter',
      facts: {'channel': 'beta'},
    );
    expect(
      manualUpdateCommand(candidate),
      '/opt/flutter/bin/flutter channel stable\n'
      '/opt/flutter/bin/flutter upgrade',
    );
  });

  testWidgets('the shim notice comes first, and Continue answers it',
      (tester) async {
    final tools = _ScriptedTools(inventory: fvmWithoutShimInventory)
      ..needsFlutterNotice = true;
    await pumpScreen(tester, tools);
    await settleDialog(tester);

    expect(find.byType(FlutterShimNotice), findsOneWidget);
    expect(find.textContaining('App Studio found FVM'), findsOneWidget);
    // Nothing else is started behind it.
    expect(tools.preflights, 0);

    await tester.tap(find.text('Continue'));
    await settleDialog(tester);
    await settleDialog(tester);

    expect(find.byType(FlutterShimNotice), findsNothing);
    expect(tools.needsFlutterNotice, isFalse);
    expect(tools.preflights, 1);
  });

  testWidgets('Check again closes the notice once a shim is found',
      (tester) async {
    final tools = _ScriptedTools(inventory: fvmWithoutShimInventory)
      ..needsFlutterNotice = true
      ..shimFoundOnRefresh = true;
    await pumpScreen(tester, tools);
    await settleDialog(tester);

    await tester.tap(find.text('Check again'));
    await settleDialog(tester);
    await settleDialog(tester);

    expect(find.byType(FlutterShimNotice), findsNothing);
    expect(tools.needsFlutterNotice, isFalse);
    // Setup carries on to the install, as it would have after Continue.
    expect(tools.preflights, 1);
  });

  testWidgets('Check again stays put, and says so, while there is none',
      (tester) async {
    final tools = _ScriptedTools(inventory: fvmWithoutShimInventory)
      ..needsFlutterNotice = true;
    await pumpScreen(tester, tools);
    await settleDialog(tester);

    await tester.tap(find.text('Check again'));
    await settleDialog(tester);

    expect(find.byType(FlutterShimNotice), findsOneWidget);
    expect(find.textContaining('Still no flutter on your PATH'), findsOneWidget);
    expect(tools.needsFlutterNotice, isTrue);
    expect(tools.preflights, 0);
  });

  testWidgets('the notice on its own still holds the setup screen',
      (tester) async {
    // Every tool fine, and FVM with no shim: nothing to install, and the
    // notice still has to be answered.
    final tools = _ScriptedTools(inventory: completeInventory)
      ..needsFlutterNotice = true;
    expect(tools.needsSetup, isTrue);

    await pumpScreen(tester, tools);
    await settleDialog(tester);
    expect(find.byType(FlutterShimNotice), findsOneWidget);

    await tester.tap(find.text('Continue'));
    await settleDialog(tester);
    expect(tools.needsSetup, isFalse);
    expect(tools.preflights, 0);
  });

  group('shimSteps', () {
    test('FVM on macOS writes the Serverpod CLI\'s shim', () {
      final commands = shimSteps(FlutterWrapper.fvm, windows: false)
          .map((s) => s.command)
          .join('\n');
      expect(commands, contains('~/.fvm_shim/flutter'));
      expect(commands, contains(r'exec fvm flutter "$@"'));
      expect(commands, contains(r'export PATH="$HOME/.fvm_shim:$PATH"'));
      expect(commands, contains('fvm global stable'));
    });

    test('FVM on Windows writes a flutter.bat', () {
      final commands = shimSteps(FlutterWrapper.fvm, windows: true)
          .map((s) => s.command)
          .join('\n');
      expect(commands, contains(r'.fvm_shim\flutter.bat'));
      expect(commands, contains('@fvm flutter %*'));
      expect(commands, isNot(contains('~/')));
    });

    test('Puro only goes back on PATH', () {
      expect(
        shimSteps(FlutterWrapper.puro, windows: false).single.command,
        r'export PATH="$HOME/.puro/bin:$PATH"',
      );
      expect(shimSteps(FlutterWrapper.puro, windows: true).single.command,
          isNull);
    });
  });

  group('manualUpdateCommand for a version-managed Flutter', () {
    ToolCandidate old(String root, {String? launcher}) => ToolCandidate(
          id: ToolId.flutter,
          source: ToolSource.host,
          fitness: ToolFitness.wrongVersion,
          root: root,
          facts: {'channel': 'stable', 'launcher': ?launcher},
        );

    test('FVM moves its global version, never runs flutter upgrade', () {
      expect(manualUpdateCommand(old('/Users/a/fvm/versions/3.41.2')),
          'fvm install stable\nfvm global stable');
    });

    test('Puro upgrades the environment the SDK is in', () {
      expect(manualUpdateCommand(old('/Users/a/.puro/envs/stable/flutter')),
          'puro upgrade stable');
      expect(
          manualUpdateCommand(
              old(r'C:\Users\a\.puro\envs\work\flutter')),
          'puro upgrade work');
    });

    test('any other shim gets no command', () {
      expect(
        manualUpdateCommand(old('/Users/a/.asdf/installs/flutter/3.41.2',
            launcher: '/Users/a/.asdf/shims/flutter')),
        isNull,
      );
    });
  });
}
