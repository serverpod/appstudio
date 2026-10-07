import 'package:appstudio/session/project_session.dart';
import 'package:appstudio/theme/app_theme.dart';
import 'package:appstudio/ui/start_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shad/shad.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The start page is drawn over a fixed brand image, so two of its rules are
/// not visible in the widget tree and are easy to undo by accident: it never
/// follows the system brightness, and it shows a shortcut rather than a
/// history.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<ProjectSession> sessionWith(List<String> recents) async {
    SharedPreferences.setMockInitialValues({'recent_projects': recents});
    final session = ProjectSession();
    await session.loadRecents();
    return session;
  }

  Future<void> pump(WidgetTester tester, ProjectSession session) async {
    await tester.pumpWidget(
      ShadApp(
        theme: buildLightTheme(),
        home: StartPage(session: session, onNewProject: () {}),
      ),
    );
    await tester.pump();
  }

  testWidgets('stays dark under a light app theme', (tester) async {
    await pump(tester, await sessionWith([]));

    final context = tester.element(find.text('Build your full-stack app'));
    expect(ShadTheme.of(context).brightness, Brightness.dark);
  });

  testWidgets('shows at most five recent projects', (tester) async {
    // More than the cap: `ProjectSession` trims as it records, but a list
    // written by an older build is read back whole, and the page is the only
    // thing standing between that and a wall of rows.
    await pump(
      tester,
      await sessionWith([for (var i = 0; i < 8; i++) '/tmp/project_$i']),
    );

    expect(find.text('project_0'), findsOneWidget);
    expect(find.text('project_4'), findsOneWidget);
    expect(find.text('project_5'), findsNothing);
  });

  testWidgets('paints a project path in white under a light app theme', (
    tester,
  ) async {
    // Resolved through DefaultTextStyle rather than read off the widget: a
    // text role with no colour of its own inherits the one `ShadApp` installed
    // from the *app* theme, which is the only thing on this screen that still
    // follows the system brightness. That is how the path — and nothing beside
    // it — came out black over the backdrop.
    await pump(tester, await sessionWith(['/tmp/project_0']));

    final paragraph = tester.renderObject<RenderParagraph>(
      find.text('/tmp/project_0'),
    );
    final color = paragraph.text.style?.color;

    expect(color, isNotNull);
    expect([color!.r, color.g, color.b], everyElement(1.0), reason: 'white');
    expect(color.a, lessThan(1.0), reason: 'a path should recede');
  });

  testWidgets('offers no recents section when there are none', (tester) async {
    await pump(tester, await sessionWith([]));

    expect(find.text('RECENT PROJECTS'), findsNothing);
    expect(find.text('New Project'), findsOneWidget);
    expect(find.text('Open Project'), findsOneWidget);
  });
}
