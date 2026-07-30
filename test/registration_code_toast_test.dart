import 'package:appstudio/preview/registration_code_toast.dart';
import 'package:appstudio/theme/app_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late List<MethodCall> clipboardCalls;

  setUp(() {
    clipboardCalls = [];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') {
        clipboardCalls.add(call);
      }
      return null;
    });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null);
  });

  Future<void> pumpToast(
    WidgetTester tester, {
    String code = '48775957',
    VoidCallback? onDismiss,
  }) async {
    await tester.pumpWidget(
      ShadApp(
        theme: buildLightTheme(),
        home: Scaffold(
          body: RegistrationCodeToast(
            code: code,
            onDismiss: onDismiss ?? () {},
          ),
        ),
      ),
    );
    await tester.pump();
  }

  testWidgets('shows the code', (tester) async {
    await pumpToast(tester);

    expect(find.text('Registration code 48775957'), findsOneWidget);
  });

  testWidgets('copy puts the code on the clipboard', (tester) async {
    await pumpToast(tester);

    await tester.tap(find.text('Copy'));
    await tester.pump();

    expect(clipboardCalls, hasLength(1));
    expect(clipboardCalls.single.arguments['text'], '48775957');
    // Confirms the copy landed.
    expect(find.text('Copied'), findsOneWidget);
  });

  testWidgets('the copied confirmation goes away again', (tester) async {
    await pumpToast(tester);

    await tester.tap(find.text('Copy'));
    await tester.pump();
    expect(find.text('Copied'), findsOneWidget);

    await tester.pump(const Duration(seconds: 3));
    expect(find.text('Copy'), findsOneWidget);
    expect(find.text('Copied'), findsNothing);
  });

  testWidgets('fits a narrow preview pane', (tester) async {
    await tester.pumpWidget(
      ShadApp(
        theme: buildLightTheme(),
        home: Scaffold(
          body: SizedBox(
            width: 260,
            child: RegistrationCodeToast(code: '48775957', onDismiss: () {}),
          ),
        ),
      ),
    );
    await tester.pump();

    expect(tester.takeException(), isNull);
  });

  testWidgets('dismiss calls back', (tester) async {
    var dismissed = 0;
    await pumpToast(tester, onDismiss: () => dismissed++);

    await tester.tap(find.byIcon(LucideIcons.x));
    await tester.pump();

    expect(dismissed, 1);
  });
}
