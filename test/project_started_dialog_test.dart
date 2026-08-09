import 'package:appstudio/session/external_editors_view.dart';
import 'package:appstudio/theme/app_theme.dart';
import 'package:appstudio/ui/project_started_dialog.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shad/shad.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _cursor = ExternalEditor(id: 'cursor', label: 'Cursor');
const _vscode = ExternalEditor(id: 'vscode', label: 'VS Code');

class _FakeEditors extends ChangeNotifier implements ExternalEditorsView {
  _FakeEditors([this.editors = const []]);

  @override
  final List<ExternalEditor> editors;

  @override
  bool get canOpen => true;

  final opened = <String>[];

  @override
  Future<void> open(ExternalEditor editor) async => opened.add(editor.id);
}

/// The notice is where a first-time user is told what to do next, and its
/// "don't show again" is a one-way door — the same trap the startup notice has.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => SharedPreferences.setMockInitialValues({}));

  Future<void> pumpAndOpen(WidgetTester tester, _FakeEditors editors) async {
    await tester.pumpWidget(
      ShadApp(
        theme: buildLightTheme(),
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () =>
                maybeShowProjectStartedNotice(context, editors: editors),
            child: const Text('open'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
  }

  testWidgets('names the editor it can open', (tester) async {
    await pumpAndOpen(tester, _FakeEditors(const [_cursor]));

    expect(find.text('Your project has started'), findsOneWidget);
    expect(
      find.textContaining('Open the project in Cursor to start building'),
      findsOneWidget,
    );
    expect(find.text('Open in Cursor'), findsOneWidget);
    expect(find.text('Dismiss'), findsOneWidget);
  });

  testWidgets('offers no button when nothing can be opened', (tester) async {
    await pumpAndOpen(tester, _FakeEditors());

    expect(find.textContaining('Open the project in your editor'), findsOne);
    // Naming no editor and offering to open one would be an offer we cannot
    // keep, so Dismiss is the only way out.
    expect(find.textContaining('Open in'), findsNothing);
  });

  testWidgets('features one editor when the project has several', (
    tester,
  ) async {
    await pumpAndOpen(tester, _FakeEditors(const [_cursor, _vscode]));

    expect(find.text('Open in Cursor'), findsOneWidget);
    expect(find.text('Open in VS Code'), findsNothing);
  });

  group('the Cursor MCP tip', () {
    testWidgets('rides along with the Cursor notice', (tester) async {
      await pumpAndOpen(tester, _FakeEditors(const [_cursor]));

      expect(
        find.textContaining('enable the Serverpod and Dart MCP servers'),
        findsOneWidget,
      );
      expect(find.byType(Image), findsOneWidget);
    });

    testWidgets('is not shown for another editor', (tester) async {
      await pumpAndOpen(tester, _FakeEditors(const [_vscode]));

      expect(find.textContaining('MCP servers'), findsNothing);
      expect(find.byType(Image), findsNothing);
    });
  });

  testWidgets('Dismiss alone does not silence it', (tester) async {
    final editors = _FakeEditors(const [_cursor]);
    await pumpAndOpen(tester, editors);
    await tester.tap(find.text('Dismiss'));
    await tester.pumpAndSettle();

    expect(find.byType(ProjectStartedDialog), findsNothing);
    expect(editors.opened, isEmpty);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getBool('project.started_notice_dismissed'), isNull);
  });

  testWidgets('ticking the box then dismissing silences it', (tester) async {
    await pumpAndOpen(tester, _FakeEditors(const [_cursor]));
    await tester.tap(find.byType(ShadCheckbox));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Dismiss'));
    await tester.pumpAndSettle();

    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getBool('project.started_notice_dismissed'), isTrue);
  });

  testWidgets('Open in … opens that editor, and can silence it too', (
    tester,
  ) async {
    final editors = _FakeEditors(const [_cursor]);
    await pumpAndOpen(tester, editors);
    await tester.tap(find.byType(ShadCheckbox));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Open in Cursor'));
    await tester.pumpAndSettle();

    expect(editors.opened, ['cursor']);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getBool('project.started_notice_dismissed'), isTrue);
  });

  testWidgets('stays silent once dismissed', (tester) async {
    SharedPreferences.setMockInitialValues({
      'project.started_notice_dismissed': true,
    });
    await pumpAndOpen(tester, _FakeEditors(const [_cursor]));

    expect(find.byType(ProjectStartedDialog), findsNothing);
  });
}
