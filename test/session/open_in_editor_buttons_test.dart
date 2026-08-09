import 'package:appstudio/session/external_editors_view.dart';
import 'package:appstudio/theme/app_theme.dart';
import 'package:appstudio/ui/open_in_editor_buttons.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shad/shad.dart';

class _FakeEditors extends ChangeNotifier implements ExternalEditorsView {
  _FakeEditors([this._editors = const [], this._canOpen = true]);

  List<ExternalEditor> _editors;
  bool _canOpen;

  final opened = <String>[];

  @override
  List<ExternalEditor> get editors => _editors;

  @override
  bool get canOpen => _canOpen;

  set canOpen(bool value) {
    _canOpen = value;
    notifyListeners();
  }

  set editors(List<ExternalEditor> value) {
    _editors = value;
    notifyListeners();
  }

  @override
  Future<void> open(ExternalEditor editor) async => opened.add(editor.id);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<void> pumpButtons(WidgetTester tester, _FakeEditors editors) async {
    await tester.pumpWidget(
      ShadApp(
        theme: buildLightTheme(),
        home: Scaffold(
          body: Center(child: OpenInEditorButtons(editors: editors)),
        ),
      ),
    );
    await tester.pump();
  }

  testWidgets('names each editor and points off to it', (tester) async {
    final editors = _FakeEditors(const [
      ExternalEditor(id: 'cursor', label: 'Cursor'),
      ExternalEditor(id: 'vscode', label: 'VS Code'),
    ]);
    await pumpButtons(tester, editors);

    expect(find.text('Open in Cursor'), findsOneWidget);
    expect(find.text('Open in VS Code'), findsOneWidget);
    expect(find.byIcon(LucideIcons.arrowUpRight), findsNWidgets(2));
  });

  testWidgets('stands the same height as the toolbar icon buttons', (
    tester,
  ) async {
    await pumpButtons(
      tester,
      _FakeEditors(const [ExternalEditor(id: 'cursor', label: 'Cursor')]),
    );

    expect(
      tester.getSize(find.byType(ShadButton)).height,
      kToolbarIconButtonSize,
    );
  });

  testWidgets('draws nothing when no editor is available', (tester) async {
    await pumpButtons(tester, _FakeEditors());

    expect(find.byType(ShadButton), findsNothing);
    expect(find.textContaining('Open in'), findsNothing);
  });

  testWidgets('stays visible but disabled until the project runs', (
    tester,
  ) async {
    final editors = _FakeEditors(const [
      ExternalEditor(id: 'cursor', label: 'Cursor'),
    ], false);
    await pumpButtons(tester, editors);

    // Visible, so the user learns the control exists during the long first
    // compile — but inert, and dimmed rather than silently doing nothing.
    expect(find.text('Open in Cursor'), findsOneWidget);
    expect(tester.widget<ShadButton>(find.byType(ShadButton)).enabled, isFalse);

    await tester.tap(find.text('Open in Cursor'), warnIfMissed: false);
    await tester.pump();
    expect(editors.opened, isEmpty);

    editors.canOpen = true;
    await tester.pump();
    expect(tester.widget<ShadButton>(find.byType(ShadButton)).enabled, isTrue);
  });

  testWidgets('a tap opens that editor', (tester) async {
    final editors = _FakeEditors(const [
      ExternalEditor(id: 'cursor', label: 'Cursor'),
      ExternalEditor(id: 'vscode', label: 'VS Code'),
    ]);
    await pumpButtons(tester, editors);

    await tester.tap(find.text('Open in VS Code'));
    await tester.pump();

    expect(editors.opened, ['vscode']);
  });

  testWidgets('follows the controller when the project changes', (
    tester,
  ) async {
    final editors = _FakeEditors(const [
      ExternalEditor(id: 'cursor', label: 'Cursor'),
    ]);
    await pumpButtons(tester, editors);
    expect(find.text('Open in Cursor'), findsOneWidget);

    editors.editors = const [];
    await tester.pump();

    expect(find.textContaining('Open in'), findsNothing);
  });
}
