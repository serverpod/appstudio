import 'dart:async';

import 'package:appstudio/platform/linux/app_version.dart';
import 'package:appstudio/update/linux/appcast.dart';
import 'package:appstudio/update/linux/linux_update_commands.dart';
import 'package:appstudio/update/linux/linux_updater.dart';
import 'package:appstudio/widgets/nothing_pushed.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shad/shad.dart';
import 'package:shared_preferences/shared_preferences.dart';

AppcastItem build(int build) => AppcastItem(
  version: AppVersion('0.4.$build', build),
  url: Uri.parse('https://updates.test/$build.AppImage'),
  length: 10,
  signature: 'c2ln',
);

/// The automatic check says something only when there is something to
/// install, and only over the start page.
void main() {
  late _FakeUpdater updater;
  late GlobalKey<NavigatorState> navigator;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    updater = _FakeUpdater();
    navigator = GlobalKey<NavigatorState>();
  });

  Future<void> run(
    WidgetTester tester,
    Future<void> Function(BuildContext) command,
  ) async {
    await tester.pumpWidget(
      ShadApp(
        navigatorKey: navigator,
        home: Builder(
          builder: (context) => ShadButton(
            onPressed: () => command(context),
            child: const Text('go'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('go'));
    await tester.pumpAndSettle();
  }

  /// A full-screen route over the start page, as New Project is.
  void pushNewProject() => unawaited(
    navigator.currentState!.push(
      PageRouteBuilder<void>(
        pageBuilder: (_, _, _) => const Text('New Project'),
      ),
    ),
  );

  /// The automatic check with the start page test `main.dart` uses.
  Future<void> checkIfDueOverStartPage(BuildContext context) =>
      LinuxUpdateSchedule(
        updater,
      ).checkIfDue(context, onStartPage: () => nothingPushedOver(navigator));

  Future<void> checkIfDue(WidgetTester tester, {bool onStartPage = true}) =>
      run(
        tester,
        (context) => LinuxUpdateSchedule(
          updater,
        ).checkIfDue(context, onStartPage: () => onStartPage),
      );

  testWidgets('offers a newer build when a check is due', (tester) async {
    updater.update = build(26);
    await checkIfDue(tester);

    expect(updater.checks, 1);
    expect(find.text('App Studio 0.4.26 is available'), findsOneWidget);
    expect(find.text('Skip This Version'), findsOneWidget);
  });

  testWidgets('does not look before a day has passed', (tester) async {
    updater
      ..due = false
      ..update = build(26);
    await checkIfDue(tester);

    expect(updater.checks, 0);
    expect(find.text('Install and Restart'), findsNothing);
  });

  testWidgets('does not look with a project open', (tester) async {
    updater.update = build(26);
    await checkIfDue(tester, onStartPage: false);

    expect(updater.checks, 0);
  });

  testWidgets('does not look with New Project open over the start page', (
    tester,
  ) async {
    updater.update = build(26);
    late BuildContext startPage;
    await run(tester, (context) async => startPage = context);
    pushNewProject();
    await tester.pumpAndSettle();

    unawaited(checkIfDueOverStartPage(startPage));
    await tester.pumpAndSettle();

    expect(updater.checks, 0);
    expect(find.text('Install and Restart'), findsNothing);

    navigator.currentState!.pop();
    await tester.pumpAndSettle();
    unawaited(checkIfDueOverStartPage(startPage));
    await tester.pumpAndSettle();
    expect(find.text('Install and Restart'), findsOneWidget);
  });

  testWidgets('offers nothing when New Project opened during the check', (
    tester,
  ) async {
    updater.update = build(26);
    final answer = Completer<void>();
    updater.checkGate = answer.future;
    await run(tester, (context) async {
      unawaited(checkIfDueOverStartPage(context));
    });
    expect(updater.checks, 1);

    pushNewProject();
    await tester.pumpAndSettle();
    answer.complete();
    await tester.pumpAndSettle();

    expect(find.text('Install and Restart'), findsNothing);
  });

  testWidgets('says nothing when there is no update', (tester) async {
    await checkIfDue(tester);

    expect(updater.checks, 1);
    expect(find.text('Install and Restart'), findsNothing);
  });

  testWidgets('says nothing when the check fails', (tester) async {
    updater.fails = true;
    await checkIfDue(tester);

    expect(find.textContaining('Could not'), findsNothing);
  });

  testWidgets('leaves out a skipped build, not a newer one', (tester) async {
    updater
      ..skipped = 26
      ..update = build(26);
    await checkIfDue(tester);
    expect(find.text('Install and Restart'), findsNothing);

    updater.update = build(27);
    await checkIfDue(tester);
    expect(find.text('Install and Restart'), findsOneWidget);
  });

  testWidgets('Help offers a skipped build anyway', (tester) async {
    updater
      ..skipped = 26
      ..update = build(26);
    await run(tester, (context) => checkForUpdatesOnLinux(context, updater));

    expect(find.text('Install and Restart'), findsOneWidget);
  });

  testWidgets('Install downloads, installs and quits', (tester) async {
    var quits = 0;
    updater.update = build(26);
    await run(
      tester,
      (context) =>
          checkForUpdatesOnLinux(context, updater, quit: () async => quits++),
    );
    await tester.tap(find.text('Install and Restart'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    expect(updater.installed, 1);
    expect(quits, 1);
  });

  testWidgets('an update installed but not started does not quit', (
    tester,
  ) async {
    var quits = 0;
    updater
      ..update = build(26)
      ..installFailsToStart = true;
    await run(
      tester,
      (context) =>
          checkForUpdatesOnLinux(context, updater, quit: () async => quits++),
    );
    await tester.tap(find.text('Install and Restart'));
    await tester.pumpAndSettle();

    expect(quits, 0);
    expect(find.text('App Studio 0.4.26 is installed'), findsOneWidget);
  });

  testWidgets('a download covered by New Project installs nothing', (
    tester,
  ) async {
    // The menu strip's Ctrl+N still works under the dialog.
    var quits = 0;
    final downloaded = Completer<void>();
    updater
      ..update = build(26)
      ..downloadGate = downloaded.future;
    await run(
      tester,
      (context) =>
          checkForUpdatesOnLinux(context, updater, quit: () async => quits++),
    );
    await tester.tap(find.text('Install and Restart'));
    await tester.pump();

    pushNewProject();
    await tester.pumpAndSettle();
    downloaded.complete();
    await tester.pumpAndSettle();

    expect(updater.installed, 0);
    expect(updater.discarded, ['/tmp/part']);
    expect(quits, 0);

    // Back under it, the dialog offers the update again.
    navigator.currentState!.pop();
    await tester.pumpAndSettle();
    expect(find.text('Install and Restart'), findsOneWidget);
  });

  testWidgets('a cancelled download installs nothing and stays', (
    tester,
  ) async {
    var quits = 0;
    updater
      ..update = build(26)
      ..downloadCancelled = true;
    await run(
      tester,
      (context) =>
          checkForUpdatesOnLinux(context, updater, quit: () async => quits++),
    );
    await tester.tap(find.text('Install and Restart'));
    await tester.pumpAndSettle();

    expect(updater.installed, 0);
    expect(quits, 0);
  });
}

class _FakeUpdater extends LinuxUpdater {
  _FakeUpdater()
    : super(
        config: const LinuxUpdateConfig(appcastUrl: 'x', publicKey: 'y'),
        environment: const {},
        executable: '/x',
      );

  bool due = true;
  bool fails = false;
  bool downloadCancelled = false;
  bool installFailsToStart = false;
  int? skipped;
  AppcastItem? update;
  int checks = 0;
  int installed = 0;
  Future<void>? checkGate;
  Future<void>? downloadGate;
  final discarded = <String>[];

  @override
  Future<AppVersion?> runningVersion() async => const AppVersion('0.4.1', 25);

  @override
  Future<bool> isCheckDue(DateTime now) async => due;

  @override
  Future<int?> skippedBuild() async => skipped;

  @override
  Future<AppcastItem?> check() async {
    checks++;
    await checkGate;
    if (fails) {
      throw const LinuxUpdateException('The update server answered 500.');
    }
    return update;
  }

  @override
  Future<VerifiedUpdate?> download(
    AppcastItem item, {
    void Function(int received, int total)? onProgress,
    UpdateCancellation? cancellation,
  }) async {
    await downloadGate;
    onProgress?.call(item.length, item.length);
    if (downloadCancelled) return null;
    return VerifiedUpdate.forTesting('/tmp/part', item);
  }

  @override
  Future<void> discard(String path) async => discarded.add(path);

  @override
  Future<void> install(VerifiedUpdate update, {int? afterPid}) async {
    installed++;
    if (installFailsToStart) {
      throw UpdateInstalledException(
        update.item.version.version,
        'App Studio could not start it. Quit App Studio and start it again.',
      );
    }
  }
}
