import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:widgetbook/widgetbook.dart';

import 'package:appstudio/ui/publish_to_cloud_button.dart';

import '../../widgetbook/catalog.dart';
import '../../widgetbook/host.dart';

/// Every use case in the Widgetbook catalog, with its path.
Iterable<(String, WidgetbookUseCase)> _useCases(
  List<WidgetbookNode> nodes, [
  String prefix = '',
]) sync* {
  for (final node in nodes) {
    final path = prefix.isEmpty ? node.name : '$prefix / ${node.name}';
    if (node is WidgetbookUseCase) yield (path, node);
    if (node.children case final children?) yield* _useCases(children, path);
  }
}

/// The use case at [path], e.g. `Open project / Studio window / Running`.
WidgetbookUseCase useCasesAt(String path) =>
    _useCases(catalog).firstWhere((entry) => entry.$1 == path).$2;

/// Builds every use case in both themes, inside the same host Widgetbook uses,
/// under an outer navigator standing in for Widgetbook's own.
///
/// This is what keeps the catalog from rotting: a use case that stops
/// compiling fails the analyzer, and one that throws on build — a fake missing
/// a member, a layout that overflows — fails here rather than the next time
/// someone opens Widgetbook to review copy. It also fails a use case that
/// pushes anything onto Widgetbook's navigator, which is what covers
/// Widgetbook's own controls.
/// The outermost navigator — Widgetbook's, in the real thing.
NavigatorState _widgetbookNavigator(WidgetTester tester) =>
    tester.state<NavigatorState>(find.byType(Navigator).first);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('a dialog opened from inside a use case stays in the canvas',
      (tester) async {
    // The toolbar's Publish to Cloud button raises a dialog of its own. shad
    // puts dialogs on the root navigator by default, which in Widgetbook is
    // Widgetbook's — this is what `showAppDialog` is for.
    tester.view.physicalSize = const Size(1440, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final running = useCasesAt('Open project / Studio window / Running');

    await tester.pumpWidget(
      MaterialApp(
        home: UseCaseHost(
          brightness: Brightness.light,
          child: Builder(builder: running.builder),
        ),
      ),
    );
    await tester.tap(find.text('Publish to Cloud'));
    await tester.pump(const Duration(milliseconds: 500));

    expect(find.byType(PublishToCloudDialog), findsOneWidget);
    expect(_widgetbookNavigator(tester).canPop(), isFalse);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 1));
  });

  final useCases = _useCases(catalog).toList();

  test('the catalog has use cases', () {
    expect(useCases.length, greaterThan(50));
  });

  for (final (path, useCase) in useCases) {
    for (final brightness in Brightness.values) {
      testWidgets('$path — ${brightness.name}', (tester) async {
        // A roomy desktop window, as Widgetbook's canvas is.
        tester.view.physicalSize = const Size(1440, 900);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);

        await tester.pumpWidget(
          MaterialApp(
            home: UseCaseHost(
              brightness: brightness,
              child: Builder(builder: useCase.builder),
            ),
          ),
        );
        // Route use cases push their dialog from a post-frame callback.
        await tester.pump();
        // Fixed pumps, never pumpAndSettle: spinners and indeterminate bars
        // animate forever.
        await tester.pump(const Duration(milliseconds: 500));

        expect(tester.takeException(), isNull);
        expect(
          _widgetbookNavigator(tester).canPop(),
          isFalse,
          reason: 'pushed a route onto Widgetbook\'s navigator',
        );
        expect(find.text('Closed.'), findsNothing, reason: 'closed itself');

        // Unmount, then let any simulated delay run out, so no timer is left
        // pending when the test ends.
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump(const Duration(seconds: 30));
      });
    }
  }
}
