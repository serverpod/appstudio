import 'dart:async';

import 'package:appstudio/previews/preview_data.dart';
import 'package:appstudio/theme/app_theme.dart';
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

  testWidgets('survives the widget preview scaffold', (tester) async {
    // LandingScaffold is a Column with an Expanded, so it needs a bounded
    // height. `previewShell` centres its child, and a preview that throws on
    // layout is a surface with no other automated coverage.
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
    expect(find.text('Set up toolchain'), findsOneWidget);
    // The plan is fully populated the moment it appears.
    expect(find.text('Flutter SDK'), findsOneWidget);
    expect(find.text('Download'), findsOneWidget);
  });

  testWidgets('a failed preflight explains itself and retries on demand',
      (tester) async {
    final tools = _ScriptedTools(inventory: emptyInventory);
    await pumpScreen(tester, tools);

    tools.answer('Could not reach the download server for Flutter SDK.');
    await settleDialog(tester);

    expect(find.byType(ToolchainSetupErrorDialog), findsOneWidget);
    expect(
      find.text('Could not reach the download server for Flutter SDK.'),
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
    // A newer published manifest can pin versions the host already satisfies.
    // The plan dialog only closes itself once an install has run, so an empty
    // one would sit there forever over the shell main.dart has switched to.
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
}
