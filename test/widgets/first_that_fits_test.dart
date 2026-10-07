import 'package:appstudio/widgets/first_that_fits.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  Future<void> pumpAt(WidgetTester tester, double width) =>
      tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: Align(
            alignment: Alignment.topLeft,
            child: SizedBox(
              width: width,
              child: Align(
                alignment: Alignment.centerLeft,
                child: FirstThatFits(
                  children: [
                    SizedBox(key: const Key('full'), width: 300, height: 20),
                    SizedBox(key: const Key('compact'), width: 120, height: 20),
                  ],
                ),
              ),
            ),
          ),
        ),
      );

  testWidgets('the full child while it fits', (tester) async {
    await pumpAt(tester, 400);

    expect(find.byKey(const Key('full')), findsOneWidget);
    expect(find.byKey(const Key('compact')), findsNothing);
    expect(tester.getSize(find.byType(FirstThatFits)).width, 300);
  });

  testWidgets('the fallback once it does not', (tester) async {
    await pumpAt(tester, 299);

    expect(find.byKey(const Key('full')), findsNothing);
    expect(find.byKey(const Key('compact')), findsOneWidget);
    expect(tester.getSize(find.byType(FirstThatFits)).width, 120);
  });

  testWidgets('the last child when nothing fits, squeezed', (tester) async {
    await pumpAt(tester, 80);

    expect(find.byKey(const Key('compact')), findsOneWidget);
    expect(tester.getSize(find.byType(FirstThatFits)).width, 80);
  });
}
