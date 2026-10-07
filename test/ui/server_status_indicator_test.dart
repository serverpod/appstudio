import 'package:appstudio/runner/server_status.dart';
import 'package:appstudio/theme/app_theme.dart';
import 'package:appstudio/ui/server_status_indicator.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shad/shad.dart';

import '../../widgetbook/fakes/runner.dart';

void main() {
  Future<FakeServerStatus> pump(
    WidgetTester tester,
    ServerStatus initial, {
    bool showMessage = true,
  }) async {
    final status = FakeServerStatus(initial);
    await tester.pumpWidget(
      ShadApp(
        theme: buildLightTheme(),
        home: Scaffold(
          body: ServerStatusIndicator(
            status: status,
            showMessage: showMessage,
          ),
        ),
      ),
    );
    return status;
  }

  BoxDecoration mark(WidgetTester tester) => tester
      .widgetList<Container>(find.byType(Container))
      .map((c) => c.decoration)
      .whereType<BoxDecoration>()
      .single;

  testWidgets('running is a green dot', (tester) async {
    await pump(tester, const ServerStatus.running());
    final theme = buildLightTheme();

    expect(find.text('Running'), findsOneWidget);
    expect(mark(tester).shape, BoxShape.circle);
    expect(mark(tester).color, theme.colorScheme.success);
  });

  testWidgets('stopped is a red rounded square', (tester) async {
    await pump(tester, const ServerStatus.stopped('Stopped'));
    final theme = buildLightTheme();

    expect(mark(tester).shape, BoxShape.rectangle);
    expect(mark(tester).borderRadius, isNotNull);
    expect(mark(tester).color, theme.colorScheme.destructive);
  });

  testWidgets('busy is a spinner beside the latest message', (tester) async {
    final status = await pump(
      tester,
      const ServerStatus.busy('Compiling server'),
    );
    expect(find.byType(ShadSpinner), findsOneWidget);
    expect(find.text('Compiling server'), findsOneWidget);

    status
      ..serverStatus = const ServerStatus.busy('Starting server')
      ..notifyListeners();
    await tester.pump();

    expect(find.text('Starting server'), findsOneWidget);
    expect(find.text('Compiling server'), findsNothing);
  });

  testWidgets('mark only, for the compact window, keeps the message for the '
      'tooltip', (tester) async {
    await pump(
      tester,
      const ServerStatus.busy('Compiling server'),
      showMessage: false,
    );

    expect(find.byType(ShadSpinner), findsOneWidget);
    expect(find.text('Compiling server'), findsNothing);
    expect(find.byType(ShadTooltip), findsOneWidget);
  });
}
