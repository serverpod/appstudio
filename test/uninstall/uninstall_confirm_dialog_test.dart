import 'package:appstudio/theme/app_theme.dart';
import 'package:appstudio/toolchain/tool_status.dart';
import 'package:appstudio/ui/uninstall/uninstall_confirm_dialog.dart';
import 'package:appstudio/uninstall/uninstall_result.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shad/shad.dart';

void main() {
  group('effectiveUninstallSelection', () {
    const all = [ToolId.serverpodCli, ToolId.flutter, ToolId.commandLineTools];

    test('removing Flutter takes the Serverpod CLI with it', () {
      expect(
        effectiveUninstallSelection({ToolId.flutter}, all),
        {ToolId.flutter, ToolId.serverpodCli},
      );
    });

    test('the Serverpod CLI can go on its own', () {
      expect(
        effectiveUninstallSelection({ToolId.serverpodCli}, all),
        {ToolId.serverpodCli},
      );
    });

    test('only ever what App Studio installed', () {
      // A Serverpod CLI the user installed is not App Studio's to remove, even
      // when the Flutter it runs on goes.
      expect(
        effectiveUninstallSelection({ToolId.flutter}, const [ToolId.flutter]),
        {ToolId.flutter},
      );
    });
  });

  group('UninstallConfirmDialog', () {
    Future<_Outcome> pumpDialog(
      WidgetTester tester,
      List<ToolId> removable,
    ) async {
      final outcome = _Outcome();
      await tester.pumpWidget(
        ShadApp(
          theme: buildLightTheme(),
          home: Builder(
            builder: (context) {
              WidgetsBinding.instance.addPostFrameCallback((_) async {
                outcome.choice = await showUninstallConfirmDialog(
                  context,
                  removableTools: removable,
                );
                outcome.closed = true;
              });
              return const SizedBox.shrink();
            },
          ),
        ),
      );
      return outcome;
    }

    Future<void> settle(WidgetTester tester) =>
        tester.pump(const Duration(milliseconds: 400));

    ShadCheckbox checkbox(WidgetTester tester, String label) =>
        tester.widget<ShadCheckbox>(find.ancestor(
          of: find.text(label),
          matching: find.byType(ShadCheckbox),
        ));

    testWidgets('prefills every tool App Studio installed', (tester) async {
      final outcome = await pumpDialog(
        tester,
        const [ToolId.serverpodCli, ToolId.flutter, ToolId.commandLineTools],
      );
      await settle(tester);

      for (final name in [
        'Uninstall Serverpod',
        'Uninstall Flutter',
        "Uninstall Apple's command line tools",
      ]) {
        expect(checkbox(tester, name).value, isTrue, reason: name);
      }
      // Only the command line tools reach past App Studio, so only they say
      // what removing them affects.
      expect(
        find.textContaining('If other apps use them, they may be affected.'),
        findsOneWidget,
      );

      await tester.tap(find.text('Uninstall'));
      await settle(tester);
      expect(outcome.closed, isTrue);
      final choice = outcome.choice!;
      expect(choice.tools, {
        ToolId.serverpodCli,
        ToolId.flutter,
        ToolId.commandLineTools,
      });
      // Flutter goes, so the Dart package cache goes with it.
      expect(choice.clearPubCache, isTrue);
    });

    testWidgets('the Serverpod CLI is locked in while Flutter is ticked',
        (tester) async {
      final outcome =
          await pumpDialog(tester, const [ToolId.serverpodCli, ToolId.flutter]);
      await settle(tester);

      final serverpod = checkbox(tester, 'Uninstall Serverpod');
      expect(serverpod.value, isTrue);
      expect(serverpod.enabled, isFalse);
      expect(find.textContaining('Required when removing Flutter'),
          findsOneWidget);

      await tester.tap(find.text('Uninstall Flutter'));
      await settle(tester);
      expect(checkbox(tester, 'Uninstall Serverpod').enabled, isTrue);

      await tester.tap(find.text('Uninstall Serverpod'));
      await settle(tester);
      await tester.tap(find.text('Uninstall'));
      await settle(tester);

      expect(outcome.closed, isTrue);
      expect(outcome.choice!.tools, isEmpty);
    });

    testWidgets('offers Git ticked and Developer Mode unticked', (tester) async {
      // Git is a program App Studio put there; Developer Mode is a Windows
      // setting other developer tools may have come to rely on since.
      final outcome = await pumpDialog(tester, const [
        ToolId.serverpodCli,
        ToolId.flutter,
        ToolId.git,
        ToolId.developerMode,
      ]);
      await settle(tester);

      expect(checkbox(tester, 'Uninstall Git for Windows').value, isTrue);
      expect(checkbox(tester, 'Turn off Developer Mode').value, isFalse);
      expect(find.textContaining('use git may be affected'), findsOneWidget);
      expect(find.textContaining('may rely on Developer Mode'), findsOneWidget);

      await tester.tap(find.text('Uninstall'));
      await settle(tester);
      expect(outcome.choice!.tools, {
        ToolId.serverpodCli,
        ToolId.flutter,
        ToolId.git,
      });
    });

    testWidgets('Developer Mode goes only when ticked', (tester) async {
      final outcome = await pumpDialog(tester, const [ToolId.developerMode]);
      await settle(tester);

      await tester.tap(find.text('Turn off Developer Mode'));
      await settle(tester);
      await tester.tap(find.text('Uninstall'));
      await settle(tester);

      expect(outcome.choice!.tools, {ToolId.developerMode});
    });

    testWidgets('offers no tools when App Studio installed none',
        (tester) async {
      await pumpDialog(tester, const []);
      await settle(tester);

      expect(find.textContaining('Uninstall Flutter'), findsNothing);
      // There is no separate package-cache option: it goes with Flutter.
      expect(find.textContaining('package cache'), findsNothing);
    });
  });
}

class _Outcome {
  UninstallChoice? choice;
  bool closed = false;
}
