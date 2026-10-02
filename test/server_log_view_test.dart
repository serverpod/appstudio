import 'package:appstudio/terminal/studio_terminal.dart';
import 'package:appstudio/theme/app_theme.dart';
import 'package:appstudio/ui/terminal_pane.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shad/shad.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late StudioTerminal studio;
  late List<String> writtenToServer;
  late List<String> copied;

  setUp(() {
    // The real terminal, not a bare one: half of "output only" is how
    // StudioTerminal configures it.
    studio = StudioTerminal();
    writtenToServer = [];
    studio.terminal.onOutput = writtenToServer.add;
    studio.terminal.write('Server listening on http://localhost:8080');

    copied = [];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') {
        copied.add((call.arguments as Map)['text'] as String);
      }
      if (call.method == 'Clipboard.getData') {
        return <String, dynamic>{'text': 'pasted'};
      }
      return null;
    });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null);
    studio.dispose();
  });

  // Run as macOS, the only platform the app has. Left on the test default
  // (Android), Flutter's own text-editing shortcuts bind Ctrl-C to copy and
  // would answer for a key the log is supposed to let through.
  final macOS = TargetPlatformVariant.only(TargetPlatform.macOS);

  Future<void> pumpFocusedLog(WidgetTester tester) async {
    await tester.pumpWidget(
      ShadApp(
        theme: buildLightTheme(),
        home: Scaffold(
          body: ServerLogView(terminal: studio.terminal, autofocus: true),
        ),
      ),
    );
    await tester.pump();

    // Every assertion below is about keys sent to a log that holds focus;
    // unfocused, nothing would be handled and they would all pass vacuously.
    final focused = FocusManager.instance.primaryFocus?.context;
    expect(
      focused?.findAncestorWidgetOfExactType<ServerLogView>(),
      isNotNull,
      reason: 'the server log should hold focus',
    );
  }

  /// Presses [key] with ⌘ held, as macOS delivers it: the event carries the
  /// key's character. Answers whether Flutter reported it handled — which is
  /// what decides whether the menu bar ever sees it.
  Future<bool> pressWithCommand(
    WidgetTester tester,
    LogicalKeyboardKey key,
    String character,
  ) async {
    await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft,
        platform: 'macos');
    final handled = await tester.sendKeyDownEvent(
      key,
      platform: 'macos',
      character: character,
    );
    await tester.sendKeyUpEvent(key, platform: 'macos');
    await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft,
        platform: 'macos');
    await tester.pump();
    return handled;
  }

  testWidgets('a menu shortcut passes through the focused log', (tester) async {
    await pumpFocusedLog(tester);

    final handled =
        await pressWithCommand(tester, LogicalKeyboardKey.keyW, 'w');

    expect(handled, isFalse, reason: '⌘W has to reach the menu bar');
    expect(writtenToServer, isEmpty);
  }, variant: macOS);

  testWidgets('typing reaches neither the log nor the server', (tester) async {
    await pumpFocusedLog(tester);

    final typed = await tester.sendKeyDownEvent(
      LogicalKeyboardKey.keyW,
      platform: 'macos',
      character: 'w',
    );
    await tester.sendKeyUpEvent(LogicalKeyboardKey.keyW, platform: 'macos');
    final entered =
        await tester.sendKeyEvent(LogicalKeyboardKey.enter, platform: 'macos');
    final escaped =
        await tester.sendKeyEvent(LogicalKeyboardKey.escape, platform: 'macos');

    // Ctrl-C is the one that would do damage: it is SIGINT to the server.
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft,
        platform: 'macos');
    final interrupted =
        await tester.sendKeyEvent(LogicalKeyboardKey.keyC, platform: 'macos');
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft,
        platform: 'macos');

    expect([typed, entered, escaped, interrupted], everyElement(isFalse));
    expect(writtenToServer, isEmpty);
  }, variant: macOS);

  testWidgets('select all and copy still work', (tester) async {
    await pumpFocusedLog(tester);

    expect(
      await pressWithCommand(tester, LogicalKeyboardKey.keyA, 'a'),
      isTrue,
    );
    expect(
      await pressWithCommand(tester, LogicalKeyboardKey.keyC, 'c'),
      isTrue,
    );

    expect(copied, hasLength(1));
    expect(copied.single, contains('Server listening on'));
    expect(writtenToServer, isEmpty);
  }, variant: macOS);

  testWidgets('paste does not reach the server', (tester) async {
    await pumpFocusedLog(tester);

    final handled =
        await pressWithCommand(tester, LogicalKeyboardKey.keyV, 'v');
    await tester.pump();

    expect(handled, isFalse);
    expect(writtenToServer, isEmpty);
  }, variant: macOS);
}
