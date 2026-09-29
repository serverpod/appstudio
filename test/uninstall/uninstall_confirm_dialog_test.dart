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
                  measureBytes: () async => null,
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
        'Uninstall Serverpod CLI',
        'Uninstall Flutter SDK',
        'Uninstall Command Line Tools',
      ]) {
        expect(checkbox(tester, name).value, isTrue, reason: name);
      }
      // Each says what removing it breaks.
      expect(find.textContaining('Homebrew'), findsOneWidget);
      expect(find.textContaining('Serverpod Cloud login'), findsOneWidget);

      await tester.tap(find.text('Uninstall'));
      await settle(tester);
      expect(outcome.closed, isTrue);
      final choice = outcome.choice!;
      expect(choice.tools, {
        ToolId.serverpodCli,
        ToolId.flutter,
        ToolId.commandLineTools,
      });
      expect(choice.clearPubCache, isFalse);
    });

    testWidgets('the Serverpod CLI is locked in while Flutter is ticked',
        (tester) async {
      final outcome =
          await pumpDialog(tester, const [ToolId.serverpodCli, ToolId.flutter]);
      await settle(tester);

      final serverpod = checkbox(tester, 'Uninstall Serverpod CLI');
      expect(serverpod.value, isTrue);
      expect(serverpod.enabled, isFalse);
      expect(find.textContaining('Required when removing Flutter SDK'),
          findsOneWidget);

      await tester.tap(find.text('Uninstall Flutter SDK'));
      await settle(tester);
      expect(checkbox(tester, 'Uninstall Serverpod CLI').enabled, isTrue);

      await tester.tap(find.text('Uninstall Serverpod CLI'));
      await settle(tester);
      await tester.tap(find.text('Uninstall'));
      await settle(tester);

      expect(outcome.closed, isTrue);
      expect(outcome.choice!.tools, isEmpty);
    });

    testWidgets('offers no tools when App Studio installed none',
        (tester) async {
      await pumpDialog(tester, const []);
      await settle(tester);

      expect(find.textContaining('Uninstall Flutter'), findsNothing);
      expect(find.text('Also clear the Dart package cache'), findsOneWidget);
    });
  });
}

class _Outcome {
  UninstallChoice? choice;
  bool closed = false;
}
