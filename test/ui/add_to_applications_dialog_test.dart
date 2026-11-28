import 'package:appstudio/platform/linux/app_version.dart';
import 'package:appstudio/ui/add_to_applications_dialog.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shad/shad.dart';

void main() {
  /// Opens the dialog over a page. The returned function gives what it
  /// popped, and fails while it is still open.
  Future<AddToApplicationsAnswer? Function()> open(
    WidgetTester tester, {
    required Future<void> Function() onAdd,
    String? currentFolder = '/home/alex/Downloads',
    bool offerDontAskAgain = true,
  }) async {
    AddToApplicationsAnswer? answer;
    var popped = false;
    await tester.pumpWidget(
      ShadApp(
        home: Builder(
          builder: (context) => ShadButton(
            onPressed: () async {
              answer = await showShadDialog<AddToApplicationsAnswer>(
                context: context,
                builder: (_) => AddToApplicationsDialog(
                  onAdd: onAdd,
                  currentFolder: currentFolder,
                  offerDontAskAgain: offerDontAskAgain,
                ),
              );
              popped = true;
            },
            child: const Text('open'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    return () {
      expect(popped, isTrue, reason: 'the dialog is still open');
      return answer;
    };
  }

  testWidgets('Add runs, closes and answers added', (tester) async {
    var added = 0;
    final result = await open(tester, onAdd: () async => added++);

    expect(
      find.textContaining('from /home/alex/Downloads to ~/AppImages'),
      findsOneWidget,
    );
    await tester.tap(find.text('Add'));
    await tester.pumpAndSettle();

    expect(added, 1);
    expect(result(), AddToApplicationsAnswer.added);
  });

  testWidgets('a failed Add stays open with the error', (tester) async {
    await open(
      tester,
      onAdd: () async => throw Exception('Copying the icons failed: denied'),
    );

    await tester.tap(find.text('Add'));
    await tester.pumpAndSettle();

    expect(
      find.textContaining('Copying the icons failed: denied'),
      findsOneWidget,
    );
    expect(find.text('Add'), findsOneWidget);
  });

  testWidgets('Not now asks again; with the box ticked it never does', (
    tester,
  ) async {
    var result = await open(tester, onAdd: () async {});
    await tester.tap(find.text('Not now'));
    await tester.pumpAndSettle();
    expect(result(), AddToApplicationsAnswer.notNow);

    result = await open(tester, onAdd: () async {});
    await tester.tap(find.text("Don't ask again"));
    await tester.pump();
    await tester.tap(find.text('Not now'));
    await tester.pumpAndSettle();
    expect(result(), AddToApplicationsAnswer.never);
  });

  testWidgets('from the menu it offers Cancel and no checkbox', (tester) async {
    await open(tester, onAdd: () async {}, offerDontAskAgain: false);

    expect(find.text('Cancel'), findsOneWidget);
    expect(find.text('Not now'), findsNothing);
    expect(find.text("Don't ask again"), findsNothing);
  });

  testWidgets('a file already in place names no folder', (tester) async {
    await open(tester, onAdd: () async {}, currentFolder: null);

    expect(
      find.text('App Studio will appear in your app menu.'),
      findsOneWidget,
    );
  });

  /// Shows [dialog] over a page; the function gives what it popped.
  Future<Object? Function()> show(WidgetTester tester, Widget dialog) async {
    Object? answer;
    await tester.pumpWidget(
      ShadApp(
        home: Builder(
          builder: (context) => ShadButton(
            onPressed: () async {
              answer = await showShadDialog<Object>(
                context: context,
                builder: (_) => dialog,
              );
            },
            child: const Text('open'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    return () => answer;
  }

  const older = AppVersion('0.4.1', 25);
  const newer = AppVersion('0.4.2', 26);

  testWidgets('a newer copy offers to replace the older one', (tester) async {
    var replaced = 0;
    final result = await show(
      tester,
      ReplaceAddedCopyDialog(
        running: newer,
        added: older,
        currentFolder: '/home/alex/Downloads',
        onReplace: () async => replaced++,
      ),
    );

    expect(
      find.text('Replace App Studio 0.4.1 with this version?'),
      findsOneWidget,
    );
    expect(
      find.textContaining('This copy is App Studio 0.4.2'),
      findsOneWidget,
    );
    await tester.tap(find.text('Replace'));
    await tester.pumpAndSettle();

    expect(replaced, 1);
    expect(result(), isTrue);
  });

  testWidgets('Replace says it copies where it cannot move', (tester) async {
    await show(
      tester,
      ReplaceAddedCopyDialog(
        running: newer,
        added: older,
        currentFolder: '/opt/as',
        keepsOriginal: true,
        onReplace: () async {},
      ),
    );

    expect(
      find.textContaining('Replace puts a copy of it from /opt/as into'),
      findsOneWidget,
    );
  });

  testWidgets('an older copy offers to open the newer one', (tester) async {
    final result = await show(
      tester,
      const OlderCopyDialog(running: older, added: newer),
    );

    expect(
      find.text('This copy is App Studio 0.4.1. Your app menu has 0.4.2.'),
      findsOneWidget,
    );
    await tester.tap(find.text('Open 0.4.2'));
    await tester.pumpAndSettle();

    expect(result(), isTrue);
  });

  test('the build tells two copies of one version apart', () {
    expect(copyVersionLabel(newer, older), '0.4.2');
    expect(
      copyVersionLabel(const AppVersion('0.4.1', 26), older),
      '0.4.1 (build 26)',
    );
  });
}
