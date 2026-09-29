import '../../widgetbook/fakes/providers.dart';
import 'package:appstudio/theme/app_theme.dart';
import 'package:appstudio/ui/settings/add_provider_dialog.dart';
import 'package:appstudio/ui/settings/providers_settings_pane.dart';
import 'package:appstudio/widgets/settings_table.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shad/shad.dart';

/// Stores the key but never comes back connected — what a serve that is still
/// starting up looks like from the pane.
class _FailingProvidersView extends FakeProvidersView {
  @override
  Future<void> saveApiKey(String providerId, String key) async {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<void> pumpPane(WidgetTester tester, FakeProvidersView agent) async {
    await tester.pumpWidget(
      ShadApp(
        theme: buildLightTheme(),
        home: Scaffold(body: ProvidersSettingsPane(agent: agent)),
      ),
    );
    await tester.pump();
  }

  /// Fixed pumps, never pumpAndSettle: the pane's waiting state holds a
  /// ShadSpinner that animates forever.
  Future<void> settle(WidgetTester tester) =>
      tester.pump(const Duration(milliseconds: 400));

  /// The select's options live in a popover that takes several frames to land.
  Future<void> openSelect(WidgetTester tester) async {
    await tester.tap(find.text('Select provider'));
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 200));
    }
  }

  /// Picks an option and waits for the popover to go away. Its barrier swallows
  /// the next tap while it is still closing, so a short pump here shows up as a
  /// button press that silently did nothing.
  Future<void> chooseOption(WidgetTester tester, String label) async {
    await tester.tap(find.text(label).last);
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 200));
    }
  }

  testWidgets('lists only the providers that hold a key', (tester) async {
    await pumpPane(tester, connectedProvidersFake());

    expect(find.byType(SettingsTable), findsOneWidget);
    expect(find.text('Anthropic'), findsOneWidget);
    expect(find.text('OpenAI'), findsOneWidget);
    // The pane used to render a key field for all seventeen curated providers,
    // which buried the two that were actually configured.
    expect(find.text('Groq'), findsNothing);
    expect(find.text('Mistral'), findsNothing);
    expect(find.text('Connected'), findsNWidgets(2));
    expect(find.text('Not connected'), findsNothing);
  });

  testWidgets('says so plainly when there are no keys', (tester) async {
    await pumpPane(tester, FakeProvidersView());

    expect(find.byType(SettingsTable), findsNothing);
    expect(find.textContaining('No API keys yet'), findsOneWidget);
    expect(find.text('Add Provider'), findsOneWidget);
  });

  testWidgets('the trash button removes that provider\'s key', (tester) async {
    final agent = connectedProvidersFake();
    await pumpPane(tester, agent);

    expect(agent.connectedProviders, contains('openai'));
    // Two rows, so target this provider's button by key.
    await tester.tap(find.byKey(const ValueKey('remove-key-openai')));
    await settle(tester);

    expect(agent.connectedProviders, isNot(contains('openai')));
    expect(agent.connectedProviders, contains('anthropic'));
  });

  testWidgets('Add Provider opens a dialog that hides connected providers',
      (tester) async {
    await pumpPane(tester, connectedProvidersFake());

    await tester.tap(find.text('Add Provider'));
    await settle(tester);

    expect(find.byType(AddProviderDialog), findsOneWidget);
    // Cancel is the way out; a close X beside it would say less.
    expect(find.text('Cancel'), findsOneWidget);
    expect(find.text('Connect'), findsOneWidget);

    await openSelect(tester);

    // Scoped to the dialog: the pane behind it lists the connected providers
    // by the same names.
    Finder inDialog(String label) => find.descendant(
          of: find.byType(AddProviderDialog),
          matching: find.text(label),
        );
    // anthropic and openai already hold keys.
    expect(inDialog('Google'), findsWidgets);
    expect(inDialog('Anthropic'), findsNothing);
  });

  testWidgets('Connect stays disabled until both fields are filled',
      (tester) async {
    await pumpPane(tester, FakeProvidersView());
    await tester.tap(find.text('Add Provider'));
    await settle(tester);

    ShadButton connectButton() =>
        tester.widget<ShadButton>(find.widgetWithText(ShadButton, 'Connect'));

    // `enabled`, not just onPressed: shad dims from the flag alone, so checking
    // the handler would pass on a button that still looks live.
    expect(connectButton().enabled, isFalse);

    await tester.enterText(find.byType(ShadInput), 'sk-test');
    await settle(tester);
    // A key with no provider chosen is still not connectable.
    expect(connectButton().enabled, isFalse);

    await openSelect(tester);
    await chooseOption(tester, 'Anthropic');

    expect(connectButton().enabled, isTrue);
  });

  testWidgets('connecting stores the key and lists the provider',
      (tester) async {
    final agent = FakeProvidersView();
    await pumpPane(tester, agent);

    await tester.tap(find.text('Add Provider'));
    await settle(tester);
    await tester.enterText(find.byType(ShadInput), 'sk-test');
    await openSelect(tester);
    await chooseOption(tester, 'Anthropic');
    await tester.tap(find.text('Connect'));
    // The pop animation and the save both have to land before the pane relists.
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 200));
    }

    expect(agent.connectedProviders, contains('anthropic'));
    expect(find.byType(AddProviderDialog), findsNothing);
    expect(find.text('Anthropic'), findsOneWidget);
    expect(find.text('Connected'), findsOneWidget);
  });

  testWidgets('a failed connect keeps the dialog up and says why',
      (tester) async {
    // `saveApiKey` writes to the auth store and treats that as the truth, so it
    // does not reject a wrong key. What it can report is the agent not coming
    // back connected — and losing the typed key to a closed dialog on top of
    // that would be the worst of both.
    final agent = _FailingProvidersView();
    await pumpPane(tester, agent);

    await tester.tap(find.text('Add Provider'));
    await settle(tester);
    await tester.enterText(find.byType(ShadInput), 'sk-test');
    await openSelect(tester);
    await chooseOption(tester, 'Anthropic');
    await tester.tap(find.text('Connect'));
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 200));
    }

    expect(find.byType(AddProviderDialog), findsOneWidget);
    expect(find.textContaining('did not report the provider'), findsOneWidget);
    // The key survives the failure.
    expect(
      tester.widget<ShadInput>(find.byType(ShadInput)).controller?.text,
      'sk-test',
    );
  });

  testWidgets('waits for the agent rather than reporting an empty list',
      (tester) async {
    await pumpPane(tester, FakeProvidersView(agentReady: false));

    expect(find.text('Waiting for the agent'), findsOneWidget);
    expect(find.byType(SettingsTable), findsNothing);
    expect(find.text('Add Provider'), findsNothing);
  });
}
