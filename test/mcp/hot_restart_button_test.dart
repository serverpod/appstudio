import 'package:appstudio/mcp/hot_restart_view.dart';
import 'package:appstudio/theme/app_theme.dart';
import 'package:appstudio/ui/hot_restart_button.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shad/shad.dart';

/// A [HotRestartView] with no bridge behind it, so the button's rules can be
/// checked without a Serverpod runner.
class _FakeMcp extends ChangeNotifier implements HotRestartView {
  _FakeMcp({
    this.mcpConnection = McpConnection.connected,
    this.isHotRestarting = false,
    this.hotRestartError,
  });

  @override
  McpConnection mcpConnection;
  @override
  bool isHotRestarting;
  @override
  String? hotRestartError;

  int calls = 0;

  @override
  Future<void> hotRestart() async => calls++;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<void> pumpButton(WidgetTester tester, _FakeMcp mcp) async {
    await tester.pumpWidget(
      ShadApp(
        theme: buildLightTheme(),
        home: Scaffold(body: Center(child: HotRestartButton(mcp: mcp))),
      ),
    );
    await tester.pump();
  }

  bool isEnabled(WidgetTester tester) =>
      tester.widget<ShadIconButton>(find.byType(ShadIconButton)).enabled;

  /// The tooltip is the only place the button explains itself, so it is worth
  /// asserting. It is hover-triggered and waits 700ms by theme.
  Future<void> hover(WidgetTester tester) async {
    final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await gesture.addPointer(location: Offset.zero);
    addTearDown(gesture.removePointer);
    await tester.pump();
    await gesture.moveTo(tester.getCenter(find.byType(ShadIconButton)));
    await tester.pump(const Duration(milliseconds: 900));
    await tester.pump();
  }

  testWidgets('is live only when a runner is attached', (tester) async {
    final mcp = _FakeMcp();
    await pumpButton(tester, mcp);

    expect(find.byIcon(LucideIcons.zap), findsOneWidget);
    expect(isEnabled(tester), isTrue);

    await tester.tap(find.byType(ShadIconButton));
    await tester.pump();
    expect(mcp.calls, 1);
  });

  testWidgets('a bridge with no runner behind it stays disabled', (
    tester,
  ) async {
    // The bridge process starts and answers happily with no `serverpod start`
    // attached, so "connecting" is a state the button must not treat as ready:
    // a click would be accepted and then do nothing.
    final mcp = _FakeMcp(mcpConnection: McpConnection.connecting);
    await pumpButton(tester, mcp);

    expect(isEnabled(tester), isFalse);
    await tester.tap(find.byType(ShadIconButton), warnIfMissed: false);
    await tester.pump();
    expect(mcp.calls, 0);

    await hover(tester);
    expect(find.text('Hot restart — connecting to the server'), findsOneWidget);
  });

  testWidgets('with no server running it points at starting one', (
    tester,
  ) async {
    await pumpButton(tester, _FakeMcp(mcpConnection: McpConnection.idle));

    expect(isEnabled(tester), isFalse);
    await hover(tester);
    expect(find.text('Hot restart — start the server first'), findsOneWidget);
  });

  testWidgets('shows a spinner and refuses a second click while in flight', (
    tester,
  ) async {
    final mcp = _FakeMcp(isHotRestarting: true);
    await pumpButton(tester, mcp);

    expect(find.byType(ShadSpinner), findsOneWidget);
    expect(find.byIcon(LucideIcons.zap), findsNothing);
    expect(isEnabled(tester), isFalse);

    await tester.tap(find.byType(ShadIconButton), warnIfMissed: false);
    await tester.pump();
    expect(mcp.calls, 0);
  });

  testWidgets('a failed attempt is named, not swallowed', (tester) async {
    final mcp = _FakeMcp(hotRestartError: 'Hot restart failed: boom');
    await pumpButton(tester, mcp);

    // Still live: the connection is fine, the attempt was not.
    expect(isEnabled(tester), isTrue);
    await hover(tester);
    expect(
      find.text('Hot restart failed: Hot restart failed: boom'),
      findsOneWidget,
    );
  });

  testWidgets('an unavailable bridge reports why', (tester) async {
    await pumpButton(
      tester,
      _FakeMcp(
        mcpConnection: McpConnection.unavailable,
        hotRestartError: 'Serverpod CLI is not installed.',
      ),
    );

    expect(isEnabled(tester), isFalse);
    await hover(tester);
    expect(
      find.text('Hot restart unavailable: Serverpod CLI is not installed.'),
      findsOneWidget,
    );
  });

  testWidgets('follows the controller without being rebuilt', (tester) async {
    final mcp = _FakeMcp(mcpConnection: McpConnection.connecting);
    await pumpButton(tester, mcp);
    expect(isEnabled(tester), isFalse);

    mcp
      ..mcpConnection = McpConnection.connected
      ..notifyListeners();
    await tester.pump();

    expect(isEnabled(tester), isTrue);
  });
}
