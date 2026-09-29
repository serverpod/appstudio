import '../../widgetbook/fakes/tools.dart';
import 'package:appstudio/theme/app_theme.dart';
import 'package:appstudio/toolchain/install_plan.dart';
import 'package:appstudio/toolchain/tool_status.dart';
import 'package:appstudio/ui/toolchain/manage_tools_pane.dart';
import 'package:appstudio/widgets/command_block.dart';
import 'package:appstudio/widgets/settings_table.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shad/shad.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<void> pumpPane(WidgetTester tester, FakeToolsView tools) async {
    await tester.pumpWidget(
      ShadApp(
        theme: buildLightTheme(),
        home: Scaffold(body: ManageToolsPane(toolchains: tools)),
      ),
    );
    await tester.pump();
  }

  testWidgets('lists every tool with its version and who installed it',
      (tester) async {
    await pumpPane(tester, FakeToolsView(inventory: completeInventory));

    expect(find.byType(SettingsTable), findsOneWidget);
    expect(find.text('Command Line Tools'), findsOneWidget);
    expect(find.text('Flutter SDK'), findsOneWidget);
    expect(find.text('3.47.5'), findsOneWidget);
    expect(find.text('4.0.3'), findsOneWidget);
    expect(find.text('App Studio'), findsNWidgets(2));
    expect(find.text('Native'), findsOneWidget);
  });

  testWidgets('a tool with nothing usable is Missing, with the version that '
      'would be installed', (tester) async {
    await pumpPane(
      tester,
      FakeToolsView(inventory: emptyInventory, plan: previewPlan),
    );

    expect(find.text('Missing'), findsNWidgets(3));
    expect(find.text('3.47.5'), findsOneWidget);
    expect(find.textContaining('3 tools are missing'), findsOneWidget);
  });

  testWidgets('an old copy shows what would replace it', (tester) async {
    await pumpPane(
      tester,
      FakeToolsView(inventory: mixedInventory, plan: previewPlan),
    );

    expect(find.text('3.4.1 → 4.0.3'), findsOneWidget);
    expect(find.text('Update needed'), findsOneWidget);
  });

  testWidgets('before the plan is known, an old copy shows its own version',
      (tester) async {
    await pumpPane(
      tester,
      FakeToolsView(inventory: mixedInventory, plan: InstallPlan.empty),
    );

    expect(find.text('3.4.1'), findsOneWidget);
  });

  testWidgets('a Flutter the user must update gets the command to run',
      (tester) async {
    await pumpPane(tester, FakeToolsView(inventory: manualUpdateInventory));

    expect(find.textContaining('leaves updating it to you'), findsOneWidget);
    expect(find.byType(CommandBlock), findsOneWidget);
    expect(
      find.text('~/flutter/bin/flutter upgrade'),
      findsOneWidget,
    );
    // Not also the generic "missing" banner — the specific one says it all.
    expect(find.textContaining('is missing'), findsNothing);
  });

  testWidgets('a shell App Studio cannot edit gets the lines to add by hand',
      (tester) async {
    const line = r'export PATH="$HOME/develop/flutter/bin:$PATH"';
    await pumpPane(
      tester,
      FakeToolsView(
        inventory: completeInventory,
        shellProfileLabel: null,
        manualPathLines: const [line],
      ),
    );

    expect(find.text('Add to your shell configuration'), findsOneWidget);
    expect(find.text(line), findsOneWidget);
  });

  testWidgets('says nothing about the shell in the ordinary case',
      (tester) async {
    await pumpPane(tester, FakeToolsView(inventory: completeInventory));

    expect(find.text('Add to your shell configuration'), findsNothing);
    expect(find.byType(CommandBlock), findsNothing);
  });

  testWidgets('renders with an inventory that could not be read',
      (tester) async {
    // `ToolchainController.create` falls back to an empty inventory when the
    // probe throws rather than refusing to launch, and ShadTable asserts on an
    // empty child list — so this pane has to survive it.
    await pumpPane(
      tester,
      FakeToolsView(
        inventory: ToolchainInventory(
          manifest: previewManifest,
          tools: const {},
        ),
      ),
    );

    expect(tester.takeException(), isNull);
    expect(find.byType(SettingsTable), findsOneWidget);
  });

  testWidgets('offers no per-tool removal', (tester) async {
    // Removing a tool is part of uninstalling App Studio, where the user sees
    // what else it would break.
    await pumpPane(tester, FakeToolsView(inventory: completeInventory));

    expect(find.textContaining('Uninstall'), findsNothing);
    expect(find.text('Update All'), findsNothing);
  });
}
