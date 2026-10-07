import 'package:appstudio/process/full_restart_view.dart';
import 'package:appstudio/theme/app_theme.dart';
import 'package:appstudio/ui/full_restart_button.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shad/shad.dart';

/// A [FullRestartView] with no server behind it, so the button's rules can be
/// checked without spawning a Serverpod runner.
class _FakeProcess extends ChangeNotifier implements FullRestartView {
  _FakeProcess({
    this.canRestart = true,
    this.isTransitioning = false,
    this.isStopped = false,
  });

  @override
  bool canRestart;
  @override
  bool isTransitioning;
  @override
  bool isStopped;

  int calls = 0;

  @override
  Future<void> restart() async => calls++;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<void> pumpButton(WidgetTester tester, _FakeProcess process) async {
    await tester.pumpWidget(
      ShadApp(
        theme: buildLightTheme(),
        home: Scaffold(body: Center(child: FullRestartButton(process: process))),
      ),
    );
    await tester.pump();
  }

  bool isEnabled(WidgetTester tester) =>
      tester.widget<ShadIconButton>(find.byType(ShadIconButton)).enabled;

  Future<void> hover(WidgetTester tester) async {
    final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await gesture.addPointer(location: Offset.zero);
    addTearDown(gesture.removePointer);
    await tester.pump();
    await gesture.moveTo(tester.getCenter(find.byType(ShadIconButton)));
    await tester.pump(const Duration(milliseconds: 900));
    await tester.pump();
  }

  testWidgets('restarts a running server', (tester) async {
    final process = _FakeProcess();
    await pumpButton(tester, process);

    expect(find.byIcon(LucideIcons.refreshCcwDot), findsOneWidget);
    // Icon-only, so the name has to survive as the accessibility label.
    expect(
      tester
          .widget<ShadIconButton>(find.byType(ShadIconButton))
          .semanticLabel,
      'Full Restart',
    );
    expect(isEnabled(tester), isTrue);

    await tester.tap(find.byType(ShadIconButton));
    await tester.pump();
    expect(process.calls, 1);
  });

  testWidgets('is live with the server stopped — that is the recovery path', (
    tester,
  ) async {
    // This is the case that must not be disabled. After a crash or a failed
    // compile there is nothing to stop, and this is now the only control that
    // can bring the server back; refusing to act would strand the user.
    final process = _FakeProcess(isStopped: true);
    await pumpButton(tester, process);

    expect(isEnabled(tester), isTrue);
    await tester.tap(find.byType(ShadIconButton));
    await tester.pump();
    expect(process.calls, 1);

    await hover(tester);
    expect(find.text('Full restart (⇧⌘R)'), findsOneWidget);
  });

  testWidgets('spins and refuses a second click while in flight', (
    tester,
  ) async {
    final process = _FakeProcess(canRestart: false, isTransitioning: true);
    await pumpButton(tester, process);

    expect(find.byType(ShadSpinner), findsOneWidget);
    expect(find.byIcon(LucideIcons.refreshCcwDot), findsNothing);
    expect(isEnabled(tester), isFalse);

    await tester.tap(find.byType(ShadIconButton), warnIfMissed: false);
    await tester.pump();
    expect(process.calls, 0);

    await hover(tester);
    expect(find.text('Restarting the server…'), findsOneWidget);
  });

  testWidgets('with no project it is disabled', (tester) async {
    await pumpButton(tester, _FakeProcess(canRestart: false, isStopped: true));

    expect(isEnabled(tester), isFalse);
  });

  testWidgets('follows the controller', (tester) async {
    final process = _FakeProcess(canRestart: false, isTransitioning: true);
    await pumpButton(tester, process);
    expect(isEnabled(tester), isFalse);

    process
      ..canRestart = true
      ..isTransitioning = false
      ..notifyListeners();
    await tester.pump();

    expect(isEnabled(tester), isTrue);
    expect(find.byType(ShadSpinner), findsNothing);
  });
}
