import 'package:appstudio/theme/app_theme.dart';
import 'package:appstudio/ui/publish_to_cloud_button.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shad/shad.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('opens the Serverpod Cloud notice, closed by OK alone', (
    tester,
  ) async {
    await tester.pumpWidget(
      ShadApp(
        theme: buildLightTheme(),
        home: const Scaffold(body: Center(child: PublishToCloudButton())),
      ),
    );
    await tester.pump();

    expect(find.byIcon(LucideIcons.cloudUpload), findsOneWidget);
    expect(find.text('Publish to Cloud'), findsOneWidget);
    expect(find.byType(ShadTooltip), findsNothing);

    await tester.tap(find.byType(ShadButton));
    await tester.pumpAndSettle();

    expect(find.text('Publish to Serverpod Cloud'), findsOneWidget);
    expect(find.textContaining('serverpod cloud launch'), findsOneWidget);
    // Alert variant: no close X, OK is the way out.
    expect(find.byIcon(LucideIcons.x), findsNothing);

    await tester.tap(find.text('OK'));
    await tester.pumpAndSettle();
    expect(find.text('Publish to Serverpod Cloud'), findsNothing);
  });
}
