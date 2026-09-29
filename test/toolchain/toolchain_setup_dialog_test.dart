import 'dart:async';

import '../../widgetbook/fakes/tools.dart';
import 'package:appstudio/theme/app_theme.dart';
import 'package:appstudio/toolchain/install_progress.dart';
import 'package:appstudio/toolchain/tool_status.dart';
import 'package:appstudio/ui/toolchain/toolchain_setup_dialog.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shad/shad.dart';

/// A [ToolsView] whose install is advanced a step at a time by the test.
///
/// The tail of a real install — the deep re-probe after the last step — is the
/// whole subject here, and it is over in about a second on a real machine,
/// which is exactly why it needs pinning.
class _ScriptedTools extends FakeToolsView {
  _ScriptedTools() : super(inventory: emptyInventory);

  final _install = Completer<void>();

  static const _ids = [ToolId.flutter, ToolId.serverpodCli];

  InstallProgress _progressAt(ToolPhase phase) => InstallProgress(
        startedAt: DateTime.utc(2026, 1, 1, 12),
        now: DateTime.utc(2026, 1, 1, 12, 0, 40),
        tools: [
          for (final id in _ids)
            ToolProgress(
              id: id,
              phase: phase,
              receivedBytes: phase == ToolPhase.done ? 100 : 40,
              totalBytes: 100,
            ),
        ],
      );

  @override
  Future<void> installMissing() {
    progress = _progressAt(ToolPhase.downloading);
    isInstalling = true;
    notifyListeners();
    return _install.future;
  }

  /// Every step has finished. The controller holds `isInstalling` through the
  /// re-probe that follows, so this does not clear it.
  void landDownloads() {
    progress = _progressAt(ToolPhase.done);
    notifyListeners();
  }

  /// The re-probe came back and the toolchain is complete — `installMissing`
  /// returns here.
  void finishReprobe() {
    isInstalling = false;
    inventory = completeInventory;
    notifyListeners();
    _install.complete();
  }
}

/// Stands in for `ShadApp.home` — the screen the dialog is raised over, and the
/// thing an over-eager `Navigator.pop` would take with it.
const homeKey = ValueKey('home');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  /// Fixed pumps, never pumpAndSettle: an indeterminate ShadProgress animates
  /// forever, so settling would never complete during the tail.
  Future<void> settle(WidgetTester tester) =>
      tester.pump(const Duration(milliseconds: 400));

  Future<void> pumpDialog(WidgetTester tester, _ScriptedTools tools) async {
    await tester.pumpWidget(
      ShadApp(
        theme: buildLightTheme(),
        home: Builder(
          builder: (context) {
            WidgetsBinding.instance.addPostFrameCallback(
              (_) => unawaited(
                showToolchainSetupDialog(context, toolchains: tools),
              ),
            );
            return const SizedBox.shrink(key: homeKey);
          },
        ),
      ),
    );
    await settle(tester);
  }

  Future<void> startDownload(WidgetTester tester, _ScriptedTools tools) async {
    await tester.tap(find.text('Install'));
    await settle(tester);
  }

  testWidgets('the plan is one plain sentence and the tools', (tester) async {
    final tools = _ScriptedTools();
    await pumpDialog(tester, tools);

    expect(
      find.text('App Studio will install the following developer tools.'),
      findsOneWidget,
    );
    expect(find.text('Apple\'s command line tools'), findsOneWidget);
    expect(find.text('Flutter'), findsOneWidget);
    expect(find.text('Serverpod'), findsOneWidget);
    // Nothing technical on the right: no sizes, no command names.
    expect(find.textContaining('MB'), findsNothing);
    expect(find.textContaining('dart install'), findsNothing);
  });

  testWidgets('the plan gives way to progress on Install', (tester) async {
    final tools = _ScriptedTools();
    await pumpDialog(tester, tools);

    expect(find.text('Install'), findsOneWidget);
    await startDownload(tester, tools);

    expect(find.text('Downloading Flutter…'), findsOneWidget);
    expect(find.text('Install'), findsNothing);
  });

  testWidgets('the tail after the last step is "Finishing up", not the plan',
      (tester) async {
    // The bug this pins: the plan came back for the second the re-probe took,
    // so the last thing the user saw before the dialog closed was the screen
    // they had started on.
    final tools = _ScriptedTools();
    await pumpDialog(tester, tools);
    await startDownload(tester, tools);

    tools.landDownloads();
    await settle(tester);

    expect(find.text('Finishing up…'), findsOneWidget);
    expect(find.text('Install'), findsNothing);
    expect(find.text('Quit'), findsNothing);
  });

  testWidgets('cancel dims once there is no step left to stop',
      (tester) async {
    final tools = _ScriptedTools();
    await pumpDialog(tester, tools);
    await startDownload(tester, tools);

    ShadButton cancel() =>
        tester.widget<ShadButton>(find.widgetWithText(ShadButton, 'Cancel'));
    expect(cancel().enabled, isTrue);

    tools.landDownloads();
    await settle(tester);

    // Still there rather than gone: a button that vanishes under the pointer
    // reads as a misclick.
    expect(cancel().enabled, isFalse);
  });

  testWidgets('closes itself once the install has returned', (tester) async {
    final tools = _ScriptedTools();
    await pumpDialog(tester, tools);
    await startDownload(tester, tools);

    tools.landDownloads();
    tools.finishReprobe();
    await settle(tester);
    // A second pump for the route's exit transition.
    await settle(tester);

    expect(find.byType(ToolchainSetupDialog), findsNothing);
    expect(find.byKey(homeKey), findsOneWidget);
  });

  testWidgets('being closed from outside does not take the screen with it',
      (tester) async {
    // `main.dart` clears everything pushed over `home` when the toolchain gate
    // flips, and that flip arrives while this dialog is still finishing up — so
    // it is routinely closed from outside. Popping again afterwards pops `home`
    // instead, leaving an empty navigator: the white window this pins against,
    // with `home`'s page transition playing out as it goes.
    final tools = _ScriptedTools();
    await pumpDialog(tester, tools);
    await startDownload(tester, tools);

    tools.landDownloads();
    await settle(tester);

    // Taken off in the window where the route is gone from the history but this
    // dialog's State has not been unmounted yet — one frame wide, and the one
    // the end of the install lands in.
    final route = ModalRoute.of(
      tester.element(find.byType(ToolchainSetupDialog)),
    )!;
    tester.state<NavigatorState>(find.byType(Navigator)).removeRoute(route);
    tools.finishReprobe();

    await tester.pump();
    // Long enough for a page transition to have finished, which is what made
    // this look like a screen sliding away rather than a dialog closing.
    await tester.pump(const Duration(seconds: 2));

    expect(tester.takeException(), isNull);
    expect(find.byType(ToolchainSetupDialog), findsNothing);
    expect(find.byKey(homeKey), findsOneWidget);
  });

  testWidgets('the plan comes back when the install failed', (tester) async {
    final tools = _ScriptedTools();
    await pumpDialog(tester, tools);
    await startDownload(tester, tools);

    tools.landDownloads();
    tools.installError = 'dart install serverpod_cli failed.';
    tools.finishReprobe();
    await settle(tester);

    // The dialog is the only thing on screen, so a failure has to leave the
    // user something to press.
    expect(find.byType(ToolchainSetupDialog), findsOneWidget);
    expect(find.text('dart install serverpod_cli failed.'), findsOneWidget);
    expect(find.text('Install'), findsOneWidget);
  });
}
