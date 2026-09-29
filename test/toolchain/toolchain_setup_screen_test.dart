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

  testWidgets('the Puro/FVM notice comes first, once, on a first launch',
      (tester) async {
    final tools = _ScriptedTools(inventory: emptyInventory)
      ..needsFlutterNotice = true;
    await pumpScreen(tester, tools);
    await settleDialog(tester);

    expect(find.byType(FlutterInstallNotice), findsOneWidget);
    expect(
      find.textContaining('Quick Start guide', findRichText: true),
      findsOneWidget,
    );
    // Nothing else is started behind it.
    expect(tools.preflights, 0);

    await tester.tap(find.text('Continue'));
    await settleDialog(tester);
    await settleDialog(tester);

    expect(find.byType(FlutterInstallNotice), findsNothing);
    expect(tools.needsFlutterNotice, isFalse);
    expect(tools.preflights, 1);
  });

  testWidgets('the notice on its own still holds the setup screen',
      (tester) async {
    // A first launch with a Flutter that is fine but not standard: nothing to
    // install, and the notice still has to be answered.
    final tools = _ScriptedTools(inventory: completeInventory)
      ..needsFlutterNotice = true;
    expect(tools.needsSetup, isTrue);

    await pumpScreen(tester, tools);
    await settleDialog(tester);
    expect(find.byType(FlutterInstallNotice), findsOneWidget);

    await tester.tap(find.text('Continue'));
    await settleDialog(tester);
    expect(tools.needsSetup, isFalse);
    expect(tools.preflights, 0);
  });
}
