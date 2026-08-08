import 'package:appstudio/theme/app_theme.dart';
import 'package:appstudio/ui/project_startup_dialog.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shad/shad.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The notice is the only warning that a first start takes minutes, and its
/// "don't show again" is a one-way door: if the preference is written when the
/// box was never ticked, the explanation is gone for good and the wait looks
/// like a hang. Both directions are covered here.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => SharedPreferences.setMockInitialValues({}));

  /// Pumps a host that opens the notice as soon as it is mounted, the way
  /// opening a project does.
  Future<void> pumpAndOpen(WidgetTester tester) async {
    await tester.pumpWidget(
      ShadApp(
        theme: buildLightTheme(),
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () => maybeShowProjectStartupNotice(context),
            child: const Text('open'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
  }

  testWidgets('shows on a fresh install and explains the wait', (tester) async {
    await pumpAndOpen(tester);

    expect(find.byType(ProjectStartupDialog), findsOneWidget);
    expect(find.textContaining('minute or two'), findsOneWidget);
  });

  testWidgets('dismissing alone does not silence it', (tester) async {
    await pumpAndOpen(tester);
    await tester.tap(find.text("Let's Go"));
    await tester.pumpAndSettle();

    expect(find.byType(ProjectStartupDialog), findsNothing);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getBool('project.startup_notice_dismissed'), isNull);
  });

  testWidgets('ticking the box then dismissing silences it', (tester) async {
    await pumpAndOpen(tester);
    await tester.tap(find.byType(ShadCheckbox));
    await tester.pumpAndSettle();
    await tester.tap(find.text("Let's Go"));
    await tester.pumpAndSettle();

    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getBool('project.startup_notice_dismissed'), isTrue);
  });

  testWidgets('stays silent once dismissed', (tester) async {
    SharedPreferences.setMockInitialValues({
      'project.startup_notice_dismissed': true,
    });
    await pumpAndOpen(tester);

    expect(find.byType(ProjectStartupDialog), findsNothing);
  });
}
