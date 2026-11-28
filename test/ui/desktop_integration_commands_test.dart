import 'dart:io';

import 'package:appstudio/platform/host_platform.dart';
import 'package:appstudio/platform/linux/desktop_integration.dart';
import 'package:appstudio/ui/desktop_integration_commands.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shad/shad.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The preference behind "Don't ask again" is a one-way door, so both
/// directions are pinned: what sets it, and what must not.
void main() {
  late _FakeIntegration desktop;
  late DesktopIntegrationController controller;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    desktop = _FakeIntegration();
    controller = DesktopIntegrationController(integration: desktop);
  });

  Future<bool?> declined() async => (await SharedPreferences.getInstance())
      .getBool(kAddToApplicationsDeclinedKey);

  /// Pumps a page whose button runs [command] with the navigator's context.
  Future<void> run(
    WidgetTester tester,
    Future<void> Function(BuildContext) command,
  ) async {
    await tester.pumpWidget(
      ShadApp(
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

  Future<void> offer(WidgetTester tester, {bool onStartPage = true}) => run(
    tester,
    (context) => maybeOfferAddToApplications(
      context,
      controller,
      onStartPage: () => onStartPage,
    ),
  );

  testWidgets('Not now leaves the question for the next start', (tester) async {
    await offer(tester);
    await tester.tap(find.text('Not now'));
    await tester.pumpAndSettle();

    expect(await declined(), isNull);
  });

  testWidgets("Don't ask again stops the question", (tester) async {
    await offer(tester);
    await tester.tap(find.text("Don't ask again"));
    await tester.pump();
    await tester.tap(find.text('Not now'));
    await tester.pumpAndSettle();

    expect(await declined(), isTrue);
  });

  testWidgets('Add does not write the preference', (tester) async {
    await offer(tester);
    await tester.tap(find.text('Add'));
    await tester.pumpAndSettle();

    expect(desktop.added, 1);
    expect(await declined(), isNull);
  });

  testWidgets('a declined question is not asked', (tester) async {
    SharedPreferences.setMockInitialValues({
      kAddToApplicationsDeclinedKey: true,
    });
    await offer(tester);

    expect(find.text('Add'), findsNothing);
  });

  testWidgets('no question once a project is open', (tester) async {
    await offer(tester, onStartPage: false);

    expect(find.text('Add'), findsNothing);
  });

  testWidgets('Remove stops the question, even when it fails halfway', (
    tester,
  ) async {
    desktop
      ..current = DesktopIntegrationStatus.addedByAppStudio
      ..removeFails = true;
    await run(tester, (context) => removeFromApplications(context, controller));
    await tester.tap(find.text('Remove'));
    await tester.pumpAndSettle();

    expect(desktop.removed, 1);
    expect(await declined(), isTrue);
  });

  testWidgets('says the original stays where Add can only copy it', (
    tester,
  ) async {
    desktop.keeps = true;
    await offer(tester);

    expect(find.textContaining('with a copy of the file in'), findsOneWidget);
    expect(
      find.textContaining('stays, since App Studio cannot move it'),
      findsOneWidget,
    );
    expect(find.textContaining('the file moves'), findsNothing);
  });

  testWidgets('a file already at the target is named', (tester) async {
    desktop.replaces = true;
    await offer(tester);

    expect(
      find.textContaining(
        'It replaces the App Studio already at '
        '/home/alex/AppImages/AppStudio-x86_64.AppImage.',
      ),
      findsOneWidget,
    );
  });

  group('the newer copy in the app menu', () {
    late int quits;

    setUp(() {
      quits = 0;
      desktop
        ..current = DesktopIntegrationStatus.addedByAppStudio
        ..copy = const OtherCopy(
          running: AppVersion('0.4.0', 24),
          added: AppVersion('0.4.1', 25),
        );
    });

    Future<void> offerOlder(WidgetTester tester) => run(
      tester,
      (context) => maybeOfferAddToApplications(
        context,
        controller,
        onStartPage: () => true,
        quit: () async => quits++,
      ),
    );

    testWidgets('Open starts it and quits this copy', (tester) async {
      await offerOlder(tester);
      await tester.tap(find.text('Open 0.4.1'));
      await tester.pumpAndSettle();

      expect(desktop.opened, 1);
      expect(quits, 1);
    });

    testWidgets('Keep using this one does neither', (tester) async {
      await offerOlder(tester);
      await tester.tap(find.text('Keep using this one'));
      await tester.pumpAndSettle();

      expect(desktop.opened, 0);
      expect(quits, 0);
    });

    testWidgets('a gone file is said, and nothing quits', (tester) async {
      desktop.openFails = true;
      await offerOlder(tester);
      await tester.tap(find.text('Open 0.4.1'));
      await tester.pumpAndSettle();

      expect(find.text('Could not open the newer App Studio'), findsOneWidget);
      expect(quits, 0);
    });
  });

  group('once per run', () {
    Future<void> offerOnce(WidgetTester tester, AddToApplicationsOffer offer) =>
        run(
          tester,
          (context) => offer.offerOnce(context, onStartPage: () => true),
        );

    testWidgets('asks the first time only', (tester) async {
      final offer = AddToApplicationsOffer(
        controller,
        host: HostPlatform.linux,
      );
      await offerOnce(tester, offer);
      expect(find.text('Add'), findsOneWidget);
      await tester.tap(find.text('Not now'));
      await tester.pumpAndSettle();

      await offerOnce(tester, offer);
      expect(find.text('Add'), findsNothing);
    });

    testWidgets('never asks on another OS', (tester) async {
      await offerOnce(
        tester,
        AddToApplicationsOffer(controller, host: HostPlatform.macos),
      );
      expect(find.text('Add'), findsNothing);
    });
  });

  testWidgets('cancelling Remove leaves the preference alone', (tester) async {
    desktop.current = DesktopIntegrationStatus.addedByAppStudio;
    await run(tester, (context) => removeFromApplications(context, controller));
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();

    expect(desktop.removed, 0);
    expect(await declined(), isNull);
  });
}

class _FakeIntegration extends DesktopIntegration {
  _FakeIntegration()
    : super(
        environment: const {'HOME': '/home/alex'},
        host: HostPlatform.linux,
        executable: '/x',
      );

  DesktopIntegrationStatus current = DesktopIntegrationStatus.notAdded;
  bool removeFails = false;
  bool replaces = false;
  bool keeps = false;
  bool openFails = false;
  OtherCopy? copy;
  int added = 0;
  int removed = 0;
  int opened = 0;

  @override
  Future<DesktopIntegrationStatus> status() async => current;

  @override
  Future<String?> currentFolder() async => '/home/alex/Downloads';

  /// Fixed, so the text the tests expect does not depend on the host's
  /// path separator.
  @override
  String get addedAppImagePath =>
      '/home/alex/AppImages/AppStudio-x86_64.AppImage';

  @override
  Future<bool> keepsOriginal() async => keeps;

  @override
  Future<bool> replacesAnotherFile() async => replaces;

  @override
  Future<OtherCopy?> otherCopy() async => copy;

  @override
  Future<void> openAddedCopyAfterExit({int? afterPid}) async {
    if (openFails) throw const FileSystemException('The AppImage is gone');
    opened++;
  }

  @override
  Future<void> add() async {
    added++;
    current = DesktopIntegrationStatus.addedByAppStudio;
  }

  @override
  Future<void> remove() async {
    removed++;
    if (removeFails) throw Exception('Removing the icons failed: denied');
    current = DesktopIntegrationStatus.notAdded;
  }
}
