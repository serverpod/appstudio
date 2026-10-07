import 'package:appstudio/runner/runner_log.dart';
import 'package:appstudio/runner/runner_protocol.dart';
import 'package:appstudio/theme/app_theme.dart';
import 'package:appstudio/ui/server_log/server_log_view.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shad/shad.dart';

import '../widgetbook/fakes/runner.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late List<String> copied;

  setUp(() {
    copied = [];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') {
        copied.add((call.arguments as Map)['text'] as String);
      }
      return null;
    });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null);
  });

  // Run as macOS, the only platform the app has. Left on the test default
  // (Android), Flutter's own text-editing shortcuts bind Ctrl-C to copy and
  // would answer for a key the log is supposed to let through.
  final macOS = TargetPlatformVariant.only(TargetPlatform.macOS);

  Future<RunnerLog> pumpLog(
    WidgetTester tester, {
    RunnerLog? log,
    LogSource source = const ServerLogSource(),
  }) async {
    final runnerLog = log ?? sampleRunnerLog(failure: true);
    tester.view.physicalSize = const Size(1200, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      ShadApp(
        theme: buildLightTheme(),
        home: Scaffold(
          body: ServerLogView(
            log: runnerLog,
            actions: FakeRunnerActions(),
            source: source,
          ),
        ),
      ),
    );
    await tester.pump();
    return runnerLog;
  }

  Finder text(String fragment) => find.textContaining(fragment, findRichText: true);

  testWidgets('shows records, operations and their durations', (tester) async {
    await pumpLog(tester);

    expect(text('Compiling server'), findsOneWidget);
    expect(text('4.9s'), findsWidgets);
    expect(text('Webserver listening'), findsOneWidget);
    // App Studio's own records interleave with the runner's.
    expect(text('serverpod runner start'), findsOneWidget);
  });

  testWidgets('the level filter keeps errors and drops the rest',
      (tester) async {
    await pumpLog(tester);
    expect(text('Webserver listening'), findsOneWidget);

    await tester.tap(find.text('All levels'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Errors only').last);
    await tester.pumpAndSettle();

    expect(text('Webserver listening'), findsNothing);
    expect(text('Slow query'), findsNothing);
    expect(text('Failed to call endpoint'), findsOneWidget);
  });

  testWidgets('search narrows the log to matching lines', (tester) async {
    await pumpLog(tester);

    await tester.enterText(find.byType(EditableText), 'webserver');
    await tester.pump();

    expect(text('Webserver listening'), findsOneWidget);
    expect(text('Compiling server'), findsNothing);

    await tester.enterText(find.byType(EditableText), 'no such thing');
    await tester.pump();
    expect(text('Nothing matches'), findsOneWidget);
  });

  testWidgets('an error shows its stack trace behind a disclosure',
      (tester) async {
    await pumpLog(tester);
    expect(text('GreetingEndpoint.hello'), findsNothing);

    await tester.tap(find.byIcon(LucideIcons.chevronRight).first);
    await tester.pump();

    expect(text('Null check operator'), findsOneWidget);
    expect(text('GreetingEndpoint.hello'), findsOneWidget);
  });

  testWidgets('an app source shows that app’s output', (tester) async {
    await pumpLog(tester, source: const AppLogSource(sampleAppId));

    expect(text('is being served at http://localhost:49301'), findsOneWidget);
    expect(text('Compiling server'), findsNothing);
    // An app's output has no levels to filter.
    expect(find.text('All levels'), findsNothing);
  });

  testWidgets('operations in flight are pinned below the log', (tester) async {
    await pumpLog(tester, log: sampleRunnerLog(launching: true));

    expect(text('Launching Demo app'), findsOneWidget);
    expect(find.byType(ShadSpinner), findsOneWidget);
  });

  testWidgets('new lines arrive while the view follows the bottom',
      (tester) async {
    final log = await pumpLog(tester);

    log.applyEvent(
      ServerLogEvent(
        RunnerLogRecord(
          time: DateTime.now(),
          level: RunnerLogLevel.info,
          message: 'A brand new line',
        ),
      ),
    );
    await tester.pump();
    await tester.pump();

    expect(text('A brand new line'), findsOneWidget);
  });

  group('keyboard', () {
    /// Presses [key] with ⌘ held, as macOS delivers it. Answers whether
    /// Flutter reported it handled — which decides whether the menu bar ever
    /// sees it.
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

    Future<void> focusLog(WidgetTester tester) async {
      await tester.tap(text('Webserver listening'));
      await tester.pump();
      final focused = FocusManager.instance.primaryFocus?.context;
      expect(
        focused?.findAncestorWidgetOfExactType<SelectionArea>(),
        isNotNull,
        reason: 'the log should hold focus',
      );
    }

    testWidgets('a menu shortcut passes through the focused log',
        (tester) async {
      await pumpLog(tester);
      await focusLog(tester);

      final handled =
          await pressWithCommand(tester, LogicalKeyboardKey.keyW, 'w');

      expect(handled, isFalse, reason: '⌘W belongs to the menu bar');
    }, variant: macOS);

    testWidgets('typing is not swallowed by the log', (tester) async {
      await pumpLog(tester);
      await focusLog(tester);

      final handled = await tester.sendKeyEvent(
        LogicalKeyboardKey.keyX,
        platform: 'macos',
      );

      expect(handled, isFalse);
    }, variant: macOS);

    testWidgets('select all and copy work', (tester) async {
      await pumpLog(tester);
      await focusLog(tester);

      expect(
        await pressWithCommand(tester, LogicalKeyboardKey.keyA, 'a'),
        isTrue,
      );
      expect(
        await pressWithCommand(tester, LogicalKeyboardKey.keyC, 'c'),
        isTrue,
      );
      expect(copied.single, contains('Webserver listening'));
    }, variant: macOS);
  });
}
