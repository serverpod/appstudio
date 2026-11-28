import 'dart:async';

import 'package:appstudio/platform/linux/app_version.dart';
import 'package:appstudio/update/linux/appcast.dart';
import 'package:appstudio/update/linux/linux_update_dialog.dart';
import 'package:appstudio/update/linux/update_signals.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shad/shad.dart';

final update = AppcastItem(
  version: const AppVersion('0.4.2', 26),
  url: Uri.parse('https://updates.test/AppStudio-0.4.2.AppImage'),
  length: 1000,
  signature: 'c2ln',
);
const current = AppVersion('0.4.1', 25);

void main() {
  /// Opens [dialog] over a page. The returned function says whether it has
  /// closed.
  Future<bool Function()> open(WidgetTester tester, Widget dialog) async {
    var closed = false;
    await tester.pumpWidget(
      ShadApp(
        home: Builder(
          builder: (context) => ShadButton(
            onPressed: () async {
              await showShadDialog<void>(
                context: context,
                builder: (_) => dialog,
              );
              closed = true;
            },
            child: const Text('open'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    // The checking phase spins forever: fixed pumps, never pumpAndSettle.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    return () => closed;
  }

  Future<bool> neverInstalls(
    AppcastItem item, {
    required void Function(int, int) onProgress,
    required UpdateCancellation cancellation,
  }) async => throw StateError('not expected');

  testWidgets('a check that finds nothing says so', (tester) async {
    final check = Completer<AppcastItem?>();
    final closed = await open(
      tester,
      LinuxUpdateDialog.check(
        current: current,
        check: () => check.future,
        install: neverInstalls,
      ),
    );
    expect(find.text('Checking for updates…'), findsOneWidget);

    check.complete(null);
    await tester.pumpAndSettle();
    expect(find.text("You're up to date"), findsOneWidget);
    expect(find.textContaining('0.4.1 is the newest'), findsOneWidget);
    await tester.tap(find.text('OK'));
    await tester.pumpAndSettle();
    expect(closed(), isTrue);
  });

  testWidgets('a failed check says why', (tester) async {
    await open(
      tester,
      LinuxUpdateDialog.check(
        current: current,
        check: () async => throw Exception('The update server answered 500.'),
        install: neverInstalls,
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Could not check for updates'), findsOneWidget);
    expect(find.textContaining('answered 500'), findsOneWidget);
  });

  testWidgets('a check that finds a build offers it', (tester) async {
    await open(
      tester,
      LinuxUpdateDialog.check(
        current: current,
        check: () async => update,
        install: neverInstalls,
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('App Studio 0.4.2 is available'), findsOneWidget);
    expect(find.textContaining('You have 0.4.1.'), findsOneWidget);
    expect(find.text('Install and Restart'), findsOneWidget);
  });

  testWidgets('the same version names the builds', (tester) async {
    await open(
      tester,
      LinuxUpdateDialog.offer(
        current: const AppVersion('0.4.2', 25),
        update: update,
        install: neverInstalls,
      ),
    );
    await tester.pumpAndSettle();
    expect(
      find.text('App Studio 0.4.2 (build 26) is available'),
      findsOneWidget,
    );
  });

  testWidgets('Later closes and installs nothing', (tester) async {
    final closed = await open(
      tester,
      LinuxUpdateDialog.offer(
        current: current,
        update: update,
        install: neverInstalls,
      ),
    );
    await tester.tap(find.text('Later'));
    await tester.pumpAndSettle();
    expect(closed(), isTrue);
  });

  testWidgets('Skip This Version skips it and closes', (tester) async {
    AppcastItem? skipped;
    final closed = await open(
      tester,
      LinuxUpdateDialog.offer(
        current: current,
        update: update,
        install: neverInstalls,
        onSkip: (item) async => skipped = item,
      ),
    );
    await tester.tap(find.text('Skip This Version'));
    await tester.pumpAndSettle();
    expect(skipped, update);
    expect(closed(), isTrue);
  });

  testWidgets('installing shows the download, then cannot be cancelled', (
    tester,
  ) async {
    late void Function(int, int) progress;
    final done = Completer<bool>();
    await open(
      tester,
      LinuxUpdateDialog.offer(
        current: current,
        update: update,
        install: (item, {required onProgress, required cancellation}) {
          progress = onProgress;
          return done.future;
        },
      ),
    );
    await tester.tap(find.text('Install and Restart'));
    await tester.pump();
    expect(find.text('Downloading App Studio 0.4.2'), findsOneWidget);

    progress(500, 1000);
    await tester.pump();
    expect(find.textContaining('of'), findsOneWidget);

    progress(1000, 1000);
    await tester.pump();
    expect(find.text('Installing App Studio 0.4.2'), findsOneWidget);
    final cancel = tester.widget<ShadButton>(
      find.widgetWithText(ShadButton, 'Cancel'),
    );
    expect(cancel.enabled, isFalse);

    // The app quits from here; finish so the test does not leak a future.
    done.complete(true);
    await tester.pump();
  });

  testWidgets('Cancel stops the download and offers it again', (tester) async {
    UpdateCancellation? seen;
    await open(
      tester,
      LinuxUpdateDialog.offer(
        current: current,
        update: update,
        install: (item, {required onProgress, required cancellation}) async {
          seen = cancellation;
          while (!cancellation.isCancelled) {
            await Future<void>.delayed(const Duration(milliseconds: 10));
          }
          return false;
        },
      ),
    );
    await tester.tap(find.text('Install and Restart'));
    await tester.pump();
    await tester.tap(find.text('Cancel'));
    await tester.pump(const Duration(milliseconds: 50));
    await tester.pumpAndSettle();

    expect(seen!.isCancelled, isTrue);
    expect(find.text('Install and Restart'), findsOneWidget);
  });

  testWidgets('a failed install says why and tries again', (tester) async {
    var tries = 0;
    await open(
      tester,
      LinuxUpdateDialog.offer(
        current: current,
        update: update,
        install: (item, {required onProgress, required cancellation}) async {
          tries++;
          throw Exception('The download does not carry a valid signature.');
        },
      ),
    );
    await tester.tap(find.text('Install and Restart'));
    await tester.pumpAndSettle();
    expect(find.text('Could not update App Studio'), findsOneWidget);
    expect(find.textContaining('valid signature'), findsOneWidget);

    await tester.tap(find.text('Try Again'));
    await tester.pumpAndSettle();
    expect(tries, 2);
  });

  testWidgets('installed but not started says so, with nothing to retry', (
    tester,
  ) async {
    await open(
      tester,
      LinuxUpdateDialog.offer(
        current: current,
        update: update,
        install: (item, {required onProgress, required cancellation}) async =>
            throw const UpdateInstalledException(
              '0.4.2',
              'App Studio could not start it. Quit App Studio and start it '
                  'again.',
            ),
      ),
    );
    await tester.tap(find.text('Install and Restart'));
    await tester.pumpAndSettle();

    expect(find.text('App Studio 0.4.2 is installed'), findsOneWidget);
    expect(find.textContaining('start it again'), findsOneWidget);
    expect(find.text('Try Again'), findsNothing);
  });

  testWidgets('taken off while downloading, it cancels', (tester) async {
    UpdateCancellation? seen;
    await open(
      tester,
      LinuxUpdateDialog.offer(
        current: current,
        update: update,
        install: (item, {required onProgress, required cancellation}) {
          seen = cancellation;
          return Completer<bool>().future;
        },
      ),
    );
    await tester.tap(find.text('Install and Restart'));
    await tester.pump();

    // A project opening clears every route.
    await tester.pumpWidget(const SizedBox());
    expect(seen!.isCancelled, isTrue);
  });
}
