import 'dart:io';

import 'package:appstudio/platform/host_platform.dart';
import 'package:appstudio/platform/linux/desktop_integration.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

/// Add to Applications, against a home folder in a temporary directory, so
/// it runs on any host.
void main() {
  late Directory root;
  late String home;
  late String appDir;
  late String appImage;
  late Map<String, String> env;
  late AppVersion running;

  const sourceEntry = '''
[Desktop Entry]
Type=Application
Name=App Studio
Exec=appstudio
Icon=dev.serverpod.appstudio
StartupWMClass=dev.serverpod.appstudio
X-AppImage-Version=0.4.1

[Desktop Action Extra]
Name=Extra
Exec=appstudio --extra
''';

  setUp(() async {
    running = const AppVersion('0.4.1', 25);
    root = await Directory.systemTemp.createTemp('desktop_integration');
    home = p.join(root.path, 'home');
    appDir = p.join(root.path, 'mount');
    appImage = p.join(home, 'Downloads', 'AppStudio-0.4.1-x86_64.AppImage');
    await File(appImage).create(recursive: true);
    await File(appImage).writeAsString('the image');
    for (final size in ['16x16', '256x256']) {
      final icon = File(
        p.join(
          appDir,
          'usr',
          'share',
          'icons',
          'hicolor',
          size,
          'apps',
          'dev.serverpod.appstudio.png',
        ),
      );
      await icon.create(recursive: true);
      await icon.writeAsString('icon $size');
    }
    final entry = File(
      p.join(
        appDir,
        'usr',
        'share',
        'applications',
        'dev.serverpod.appstudio.desktop',
      ),
    );
    await entry.create(recursive: true);
    await entry.writeAsString(sourceEntry);
    env = {
      'HOME': home,
      'APPIMAGE': appImage,
      'APPDIR': appDir,
      // No system folders: the machine running the tests may have its own.
      'XDG_DATA_DIRS': p.join(root.path, 'system'),
    };
  });

  tearDown(() => root.delete(recursive: true));

  DesktopIntegration integration([
    Map<String, String>? extra,
    String? executable,
  ]) => DesktopIntegration(
    environment: {...env, ...?extra},
    host: HostPlatform.linux,
    runningVersion: () async => running,
    executable:
        executable ?? p.join(appDir, 'usr', 'lib', 'appstudio', 'appstudio'),
  );

  String icon(String size) => p.join(
    home,
    '.local',
    'share',
    'icons',
    'hicolor',
    size,
    'apps',
    'dev.serverpod.appstudio.png',
  );

  String entryPath() => p.join(
    home,
    '.local',
    'share',
    'applications',
    'dev.serverpod.appstudio.desktop',
  );
  String target() => p.join(home, 'AppImages', 'AppStudio-x86_64.AppImage');

  Future<void> writeEntry(String folder, String name, String contents) async {
    final file = File(p.join(folder, name));
    await file.create(recursive: true);
    await file.writeAsString(contents);
  }

  group('status', () {
    test('an AppImage nobody added is not added', () async {
      expect(await integration().status(), DesktopIntegrationStatus.notAdded);
    });

    test('there is nothing to add outside an AppImage', () async {
      final noImage = DesktopIntegration(
        environment: {'HOME': home},
        host: HostPlatform.linux,
      );
      expect(await noImage.status(), DesktopIntegrationStatus.unavailable);
    });

    test('there is nothing to add on another OS', () async {
      // Everything else as in a real AppImage, so only the OS says no.
      final mac = DesktopIntegration(
        environment: env,
        host: HostPlatform.macos,
        runningVersion: () async => running,
        executable: p.join(appDir, 'usr', 'lib', 'appstudio', 'appstudio'),
      );
      expect(await mac.status(), DesktopIntegrationStatus.unavailable);
    });

    test('an installed tool that did not add it does not count', () async {
      // AppImageLauncher's "Run once" sets this without adding anything.
      await File(
        p.join(
          home,
          '.local',
          'lib',
          'appimagelauncher-lite',
          'appimagelauncher-lite.AppImage',
        ),
      ).create(recursive: true);
      expect(
        await integration({'DESKTOPINTEGRATION': 'AppImageLauncher'}).status(),
        DesktopIntegrationStatus.notAdded,
      );
    });

    test(
      'an entry with App Studio\'s window class is another tool\'s',
      () async {
        await writeEntry(
          p.join(home, '.local', 'share', 'applications'),
          'appimagekit_0123abcd-App_Studio.desktop',
          '[Desktop Entry]\nName=App Studio\n'
              'StartupWMClass=dev.serverpod.appstudio\n',
        );
        expect(
          await integration().status(),
          DesktopIntegrationStatus.managedByOther,
        );
      },
    );

    test(
      'an unmarked entry under the application id is another tool\'s',
      () async {
        await writeEntry(
          p.join(home, '.local', 'share', 'applications'),
          'dev.serverpod.appstudio.desktop',
          '[Desktop Entry]\nName=App Studio\nExec=/opt/appstudio\n',
        );
        expect(
          await integration().status(),
          DesktopIntegrationStatus.managedByOther,
        );
      },
    );

    test('a system entry counts too', () async {
      await writeEntry(
        p.join(root.path, 'system', 'applications'),
        'dev.serverpod.appstudio.desktop',
        '[Desktop Entry]\nName=App Studio\n',
      );
      expect(
        await integration().status(),
        DesktopIntegrationStatus.managedByOther,
      );
    });

    test('a window class in another group does not count', () async {
      await writeEntry(
        p.join(home, '.local', 'share', 'applications'),
        'other.desktop',
        '[Desktop Entry]\nName=Other\n\n[Desktop Action A]\n'
            'StartupWMClass=dev.serverpod.appstudio\n',
      );
      expect(await integration().status(), DesktopIntegrationStatus.notAdded);
    });

    test('App Studio\'s entry for a deleted AppImage does not count', () async {
      await integration().add();
      await File(target()).delete();
      expect(await integration().status(), DesktopIntegrationStatus.notAdded);
    });
  });

  group('status, an unreadable folder', () {
    test(
      'does not hide an entry beside it',
      () async {
        final uid = await Process.run('id', ['-u']);
        if ('${uid.stdout}'.trim() == '0') {
          markTestSkipped('root can read any folder');
          return;
        }
        final applications = p.join(root.path, 'system', 'applications');
        // The listing order is the file system's, so the entry sits among
        // locked folders, created before and after it: whichever order the
        // file system lists in, a locked one comes first (unless the entry
        // happens to, when the test proves nothing but cannot fail wrongly).
        Future<void> lock(String name) async {
          final folder = p.join(applications, name);
          await Directory(folder).create(recursive: true);
          await Process.run('chmod', ['000', folder]);
          addTearDown(() => Process.run('chmod', ['755', folder]));
        }

        for (var i = 0; i < 10; i++) {
          await lock('a-locked-$i');
        }
        await writeEntry(
          p.join(applications, 'm-readable'),
          'gearlever_appstudio.desktop',
          '[Desktop Entry]\nStartupWMClass=dev.serverpod.appstudio\n',
        );
        for (var i = 0; i < 10; i++) {
          await lock('z-locked-$i');
        }

        expect(
          await integration().status(),
          DesktopIntegrationStatus.managedByOther,
        );
      },
      tags: 'process',
      testOn: '!windows',
    );
  });

  group('status, beside other tools', () {
    test('a portable AppImage has nothing to add', () async {
      await Directory('$appImage.home').create();
      expect(
        await integration().status(),
        DesktopIntegrationStatus.unavailable,
      );
    });

    test(
      'another tool\'s entry for a deleted AppImage does not count',
      () async {
        await writeEntry(
          p.join(home, '.local', 'share', 'applications'),
          'app_studio.desktop',
          '[Desktop Entry]\nName=App Studio\n'
              'TryExec=${p.join(home, 'AppImages', 'app_studio.appimage')}\n'
              'StartupWMClass=dev.serverpod.appstudio\n',
        );
        expect(await integration().status(), DesktopIntegrationStatus.notAdded);
      },
    );

    test('the question names no folder for a file in ~/AppImages', () async {
      final inFolder = p.join(home, 'AppImages', 'AppStudio-0.4.1.AppImage');
      await File(inFolder).create(recursive: true);
      expect(await integration({'APPIMAGE': inFolder}).currentFolder(), isNull);
      expect(await integration().currentFolder(), p.join(home, 'Downloads'));
    });

    test('nor for a file an earlier Add moved', () async {
      await integration().add();
      expect(await integration().currentFolder(), isNull);
    });

    test('variables inherited from another AppImage do not count', () async {
      // A development build started from a terminal inside an AppImage
      // editor: the variables are that one's, the executable is not in it.
      expect(
        await integration(null, '/home/dev/appstudio/build/appstudio').status(),
        DesktopIntegrationStatus.unavailable,
      );
    });

    test('an entry in a sub-folder of applications counts', () async {
      await writeEntry(
        p.join(home, '.local', 'share', 'applications', 'kde4'),
        'appstudio.desktop',
        '[Desktop Entry]\nStartupWMClass=dev.serverpod.appstudio\n',
      );
      expect(
        await integration().status(),
        DesktopIntegrationStatus.managedByOther,
      );
    });
  });

  group('add', () {
    test('moves the AppImage, copies the icons and writes the entry', () async {
      await integration().add();

      expect(await File(appImage).exists(), isFalse);
      expect(await File(target()).readAsString(), 'the image');
      for (final size in ['16x16', '256x256']) {
        expect(
          await File(
            p.join(
              home,
              '.local',
              'share',
              'icons',
              'hicolor',
              size,
              'apps',
              'dev.serverpod.appstudio.png',
            ),
          ).readAsString(),
          'icon $size',
        );
      }
      final entry = parseDesktopEntry(await File(entryPath()).readAsString());
      expect(entry['Exec'], '"${target()}"');
      expect(entry['TryExec'], target());
      expect(entry[kAddedByKey], kAddedByValue);
      expect(entry['StartupWMClass'], 'dev.serverpod.appstudio');
      expect(
        await integration().status(),
        DesktopIntegrationStatus.addedByAppStudio,
      );
    });

    test(
      'tells the desktop about icons copied into folders that were there',
      () async {
        // An earlier Add and Remove left the size folders; GTK only rescans
        // when the theme folder itself changes.
        final hicolor = p.join(home, '.local', 'share', 'icons', 'hicolor');
        await Directory(
          p.join(hicolor, '256x256', 'apps'),
        ).create(recursive: true);
        await Directory(
          p.join(hicolor, '16x16', 'apps'),
        ).create(recursive: true);
        // `-t` reads the same on GNU and BSD touch.
        final backdated = await Process.run('touch', [
          '-t',
          '200001010000',
          hicolor,
        ]);
        expect(backdated.exitCode, 0, reason: '${backdated.stderr}');
        expect((await Directory(hicolor).stat()).modified.year, 2000);

        await integration().add();

        final modified = (await Directory(hicolor).stat()).modified;
        expect(modified.year, greaterThan(2000));
        expect(
          await Directory(
            hicolor,
          ).list().map((e) => p.basename(e.path)).toList(),
          unorderedEquals(['256x256', '16x16']),
          reason: 'nothing left behind',
        );
      },
      tags: 'process',
      testOn: '!windows',
    );

    test('leaves an AppImage already in place where it is', () async {
      await File(target()).create(recursive: true);
      await File(target()).writeAsString('in place');
      await integration({'APPIMAGE': target()}).add();

      expect(await File(target()).readAsString(), 'in place');
      expect(
        await integration({'APPIMAGE': target()}).status(),
        DesktopIntegrationStatus.addedByAppStudio,
      );
    });

    test('replaces an older AppImage at the target', () async {
      await File(target()).create(recursive: true);
      await File(target()).writeAsString('older');
      await integration().add();

      expect(await File(target()).readAsString(), 'the image');
    });

    test('honours XDG_DATA_HOME', () async {
      final dataHome = p.join(root.path, 'data');
      await integration({'XDG_DATA_HOME': dataHome}).add();

      expect(
        await File(
          p.join(dataHome, 'applications', 'dev.serverpod.appstudio.desktop'),
        ).exists(),
        isTrue,
      );
    });

    test('a failed step undoes the ones before it and says which', () async {
      await File(
        p.join(
          appDir,
          'usr',
          'share',
          'applications',
          'dev.serverpod.appstudio.desktop',
        ),
      ).delete();

      await expectLater(
        integration().add(),
        throwsA(
          isA<DesktopIntegrationException>().having(
            (e) => e.step,
            'step',
            'Writing the app menu entry',
          ),
        ),
      );
      expect(
        await Directory(
          p.join(home, '.local', 'share', 'icons', 'hicolor'),
        ).list(recursive: true).where((e) => e is File).isEmpty,
        isTrue,
      );
      expect(await File(entryPath()).exists(), isFalse);
    });

    test('a retry after a failed step finds the file it moved', () async {
      final entry = File(
        p.join(
          appDir,
          'usr',
          'share',
          'applications',
          'dev.serverpod.appstudio.desktop',
        ),
      );
      await entry.rename('${entry.path}.away');

      await expectLater(
        integration().add(),
        throwsA(
          isA<DesktopIntegrationException>().having(
            (e) => e.reason,
            'reason',
            contains('now at ~/AppImages/AppStudio-x86_64.AppImage'),
          ),
        ),
      );
      expect(await File(target()).exists(), isTrue);

      await File('${entry.path}.away').rename(entry.path);
      await integration().add();
      expect(
        await integration().status(),
        DesktopIntegrationStatus.addedByAppStudio,
      );
    });

    test(
      'copies out of a folder it cannot take the file from',
      () async {
        final uid = await Process.run('id', ['-u']);
        if ('${uid.stdout}'.trim() == '0') {
          markTestSkipped('root can take files out of any folder');
          return;
        }
        final folder = p.dirname(appImage);
        await Process.run('chmod', ['555', folder]);
        addTearDown(() => Process.run('chmod', ['755', folder]));

        await integration().add();

        expect(await File(target()).readAsString(), 'the image');
        expect(await File(appImage).exists(), isTrue, reason: 'it stays');
      },
      tags: 'process',
      testOn: 'linux',
    );

    test(
      'moves across file systems',
      () async {
        // /dev/shm is its own tmpfs on Linux, apart from the temp folder.
        final shm = Directory('/dev/shm');
        if (!await shm.exists() ||
            (await shm.stat()).type != FileSystemEntityType.directory) {
          markTestSkipped('needs /dev/shm');
          return;
        }
        final elsewhere = await shm.createTemp('desktop_integration');
        addTearDown(() => elsewhere.delete(recursive: true));
        final source = p.join(elsewhere.path, 'AppStudio.AppImage');
        await File(source).writeAsString('from afar');

        await integration({'APPIMAGE': source}).add();

        expect(await File(source).exists(), isFalse);
        expect(await File(target()).readAsString(), 'from afar');
        expect((await File(target()).stat()).modeString(), 'rwxr-xr-x');
      },
      tags: 'process',
      testOn: 'linux',
    );
  });

  // The sticky-folder rule (a shared folder such as /tmp holding someone
  // else's file) needs a second user to set up, so only the write
  // permission is tested here.
  group('a folder the file cannot be taken out of', () {
    test(
      'is said up front, where Add can only copy',
      () async {
        final uid = await Process.run('id', ['-u']);
        if ('${uid.stdout}'.trim() == '0') {
          markTestSkipped('root can take files out of any folder');
          return;
        }
        final folder = p.dirname(appImage);
        expect(await integration().keepsOriginal(), isFalse);

        await Process.run('chmod', ['555', folder]);
        addTearDown(() => Process.run('chmod', ['755', folder]));

        expect(await integration().keepsOriginal(), isTrue);
      },
      tags: 'process',
      testOn: 'linux',
    );

    test(
      'writes nothing to the folder it asks about',
      () async {
        final folder = Directory(p.dirname(appImage));
        final backdated = await Process.run('touch', [
          '-t',
          '200001010000',
          folder.path,
        ]);
        expect(backdated.exitCode, 0);

        await integration().keepsOriginal();

        expect((await folder.stat()).modified.year, 2000);
        expect(await folder.list().map((e) => p.basename(e.path)).toList(), [
          p.basename(appImage),
        ]);
      },
      tags: 'process',
      testOn: '!windows',
    );

    test('is not a question for a file in ~/AppImages already', () async {
      await integration().add();
      expect(await integration().keepsOriginal(), isFalse);
    });
  });

  group('a file already at the target', () {
    test('is named when Add would replace it', () async {
      await File(target()).create(recursive: true);
      expect(await integration().replacesAnotherFile(), isTrue);
    });

    test('is not there on a first Add', () async {
      expect(await integration().replacesAnotherFile(), isFalse);
    });

    test('is this copy itself once it was added', () async {
      await integration().add();
      // After its own Add, `$APPIMAGE` names where it was.
      expect(await integration().replacesAnotherFile(), isFalse);
      expect(
        await integration({'APPIMAGE': target()}).replacesAnotherFile(),
        isFalse,
      );
    });

    test(
      'is replaced across file systems',
      () async {
        final shm = Directory('/dev/shm');
        if (!await shm.exists()) {
          markTestSkipped('needs /dev/shm');
          return;
        }
        await File(target()).create(recursive: true);
        await File(target()).writeAsString('the older one');
        final elsewhere = await shm.createTemp('desktop_integration');
        addTearDown(() => elsewhere.delete(recursive: true));
        final source = p.join(elsewhere.path, 'AppStudio.AppImage');
        await File(source).writeAsString('the newer one');

        await integration({'APPIMAGE': source}).add();

        expect(await File(source).exists(), isFalse);
        expect(await File(target()).readAsString(), 'the newer one');
        final folder = Directory(p.dirname(target()));
        expect(await folder.list().map((f) => p.basename(f.path)).toList(), [
          p.basename(target()),
        ], reason: 'no temporary file left behind');
      },
      tags: 'process',
      testOn: 'linux',
    );
  });

  group('another copy', () {
    /// Adds a 0.4.1 (build 25), then downloads [version] to ~/Downloads and
    /// returns an integration for it.
    Future<DesktopIntegration> downloadAnother(AppVersion version) async {
      await integration().add();
      await File(appImage).writeAsString('another download');
      running = version;
      return integration();
    }

    test('the added copy itself is not another copy', () async {
      await integration().add();
      expect(await integration({'APPIMAGE': target()}).otherCopy(), isNull);
      // After its own Add, `$APPIMAGE` names where it was.
      expect(await integration().otherCopy(), isNull);
    });

    test('a newer download is newer', () async {
      final newer = await downloadAnother(const AppVersion('0.4.2', 26));
      final copy = (await newer.otherCopy())!;

      expect(copy.running, const AppVersion('0.4.2', 26));
      expect(copy.added, const AppVersion('0.4.1', 25));
      expect(copy.runningIsNewer, isTrue);
    });

    test('an older download is older', () async {
      final older = await downloadAnother(const AppVersion('0.4.0', 24));
      expect((await older.otherCopy())!.runningIsOlder, isTrue);
    });

    test('the same build is neither', () async {
      final same = await downloadAnother(const AppVersion('0.4.1', 25));
      final copy = (await same.otherCopy())!;
      expect(copy.runningIsNewer || copy.runningIsOlder, isFalse);
    });

    test('replacing puts the newer copy in place and records it', () async {
      final newer = await downloadAnother(const AppVersion('0.4.2', 26));
      await newer.add();

      expect(await File(target()).readAsString(), 'another download');
      final entry = parseDesktopEntry(await File(entryPath()).readAsString());
      expect(entry[kAddedVersionKey], '0.4.2');
      expect(entry[kAddedBuildKey], '26');
    });

    test('nothing is said without a recorded version', () async {
      running = const AppVersion('0.4.1', 25);
      await integration().add();
      final entry = File(entryPath());
      await entry.writeAsString(
        (await entry.readAsString())
            .split('\n')
            .where((l) => !l.startsWith('X-AppStudio-Build='))
            .join('\n'),
      );
      await File(appImage).writeAsString('another download');
      running = const AppVersion('0.4.2', 26);

      expect(await integration().otherCopy(), isNull);
    });
  });

  group('a failed Replace', () {
    test('keeps the icons and entry the older copy had', () async {
      await integration().add();
      final before = await File(entryPath()).readAsString();
      // A newer download whose mount has no entry: step 3 fails.
      await File(appImage).writeAsString('another download');
      await File(
        p.join(
          appDir,
          'usr',
          'share',
          'applications',
          'dev.serverpod.appstudio.desktop',
        ),
      ).delete();

      await expectLater(
        integration().add(),
        throwsA(isA<DesktopIntegrationException>()),
      );
      expect(await File(icon('256x256')).exists(), isTrue);
      // The entry stays, but no longer claims the build the file had.
      final after = await File(entryPath()).readAsString();
      expect(
        after,
        before
            .split('\n')
            .where((l) => !l.startsWith('X-AppStudio-Version='))
            .where((l) => !l.startsWith('X-AppStudio-Build='))
            .join('\n'),
      );
      expect(parseDesktopEntry(after)[kAddedByKey], kAddedByValue);
    });

    test('never offers to replace a newer file with an older one', () async {
      // The entry records 0.4.0 while the file is 0.4.2 after a failed
      // Replace. A 0.4.1 download must not be offered as newer.
      running = const AppVersion('0.4.0', 20);
      await integration().add();
      await File(appImage).writeAsString('0.4.2');
      running = const AppVersion('0.4.2', 26);
      await File(
        p.join(
          appDir,
          'usr',
          'share',
          'applications',
          'dev.serverpod.appstudio.desktop',
        ),
      ).delete();
      await expectLater(
        integration().add(),
        throwsA(isA<DesktopIntegrationException>()),
      );

      await File(appImage).writeAsString('0.4.1');
      running = const AppVersion('0.4.1', 25);
      expect(await integration().otherCopy(), isNull);
    });
  });

  group('open the added copy', () {
    /// Puts a script at the target that writes [marker] when it runs.
    Future<String> scriptAtTarget() async {
      final marker = p.join(root.path, 'started');
      await File(target()).create(recursive: true);
      await File(
        target(),
      ).writeAsString('#!/bin/sh\necho started > "$marker"\n');
      await Process.run('chmod', ['755', target()]);
      return marker;
    }

    Future<bool> appears(String path, Duration within) async {
      final end = DateTime.now().add(within);
      while (DateTime.now().isBefore(end)) {
        if (await File(path).exists()) return true;
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
      return false;
    }

    test(
      'starts it once this process has ended',
      () async {
        final marker = await scriptAtTarget();
        final ended = await Process.start('true', []);
        await ended.exitCode;

        await integration().openAddedCopyAfterExit(afterPid: ended.pid);

        expect(await appears(marker, const Duration(seconds: 5)), isTrue);
      },
      tags: 'process',
      testOn: '!windows',
    );

    test(
      'waits while this process runs',
      () async {
        final marker = await scriptAtTarget();
        final running = await Process.start('sleep', ['30']);
        addTearDown(running.kill);

        await integration().openAddedCopyAfterExit(afterPid: running.pid);

        expect(
          await appears(marker, const Duration(milliseconds: 800)),
          isFalse,
        );
        running.kill();
        await running.exitCode;
        expect(await appears(marker, const Duration(seconds: 5)), isTrue);
      },
      tags: 'process',
      testOn: '!windows',
    );

    test('refuses when the added file is gone', () async {
      await expectLater(
        integration().openAddedCopyAfterExit(),
        throwsA(isA<FileSystemException>()),
      );
    });
  });

  group('an update in place', () {
    test('records the new version in App Studio\'s entry', () async {
      await integration().add();
      await integration().recordUpdatedVersion(
        target(),
        const AppVersion('0.4.2', 26),
      );

      final entry = parseDesktopEntry(await File(entryPath()).readAsString());
      expect(entry[kAddedVersionKey], '0.4.2');
      expect(entry[kAddedBuildKey], '26');
      expect(entry[kAddedByKey], kAddedByValue);
      expect(entry['TryExec'], target());
    });

    test('leaves an entry for another file alone', () async {
      await integration().add();
      final before = await File(entryPath()).readAsString();
      await integration().recordUpdatedVersion(
        p.join(home, 'elsewhere.AppImage'),
        const AppVersion('0.4.2', 26),
      );

      expect(await File(entryPath()).readAsString(), before);
    });

    test('a version cannot add a line to the entry', () async {
      await integration().add();
      await integration().recordUpdatedVersion(
        target(),
        const AppVersion('0.4.2\nExec=/tmp/x', 26),
      );

      final lines = (await File(entryPath()).readAsString()).split('\n');
      expect(lines.where((l) => l.startsWith('Exec=/tmp')), isEmpty);
      expect(
        lines,
        contains(
          '$kAddedVersionKey='
          r'0.4.2\nExec=/tmp/x',
        ),
      );
      // And it reads back as it was written.
      expect(
        await integration().recordedVersionOf(target()),
        const AppVersion('0.4.2\nExec=/tmp/x', 26),
      );
    });

    test('leaves an entry App Studio did not write alone', () async {
      const theirs =
          '[Desktop Entry]\nName=App Studio\nExec=/opt/x\nTryExec=/opt/x\n';
      await writeEntry(
        p.dirname(entryPath()),
        'dev.serverpod.appstudio.desktop',
        theirs,
      );
      await integration().recordUpdatedVersion(
        '/opt/x',
        const AppVersion('0.4.2', 26),
      );

      expect(await File(entryPath()).readAsString(), theirs);
    });
  });

  group('remove', () {
    test('removes the entry and icons, and leaves the AppImage', () async {
      await integration().add();
      await integration().remove();

      expect(await File(entryPath()).exists(), isFalse);
      expect(
        await File(
          p.join(
            home,
            '.local',
            'share',
            'icons',
            'hicolor',
            '256x256',
            'apps',
            'dev.serverpod.appstudio.png',
          ),
        ).exists(),
        isFalse,
      );
      expect(await File(target()).exists(), isTrue);
      expect(await integration().status(), DesktopIntegrationStatus.notAdded);
    });

    test(
      'leaves an entry App Studio did not write alone, and says so',
      () async {
        const theirs = '[Desktop Entry]\nName=App Studio\nExec=/opt/x\n';
        await writeEntry(
          p.dirname(entryPath()),
          'dev.serverpod.appstudio.desktop',
          theirs,
        );
        await expectLater(
          integration().remove(),
          throwsA(isA<DesktopIntegrationException>()),
        );

        expect(await File(entryPath()).readAsString(), theirs);
      },
    );

    test('leaves no icon folder behind where there was none', () async {
      await integration().add();
      final hicolor = Directory(
        p.join(home, '.local', 'share', 'icons', 'hicolor'),
      );
      await hicolor.delete(recursive: true);

      await integration().remove();

      expect(await hicolor.exists(), isFalse);
    });

    test('says so when there is no entry to remove', () async {
      await expectLater(
        integration().remove(),
        throwsA(isA<DesktopIntegrationException>()),
      );
    });
  });

  group('desktopEntryFor', () {
    test('quotes the path as the Desktop Entry spec says', () {
      final entry = desktopEntryFor(
        sourceEntry,
        appImagePath: r'/home/a b/$x`"%\y.AppImage',
      );
      expect(entry, contains(r'Exec="/home/a b/\\$x\\`\\"%%\\\\y.AppImage"'));
      expect(entry, contains(r'TryExec=/home/a b/$x`"%\\y.AppImage'));
    });

    test('replaces Exec in the main group only and keeps the rest', () {
      final entry = desktopEntryFor(sourceEntry, appImagePath: '/a.AppImage');
      final lines = entry.split('\n');
      expect(lines.where((l) => l.startsWith('Exec=')), [
        'Exec="/a.AppImage"',
        'Exec=appstudio --extra',
      ]);
      expect(entry, contains('X-AppImage-Version=0.4.1'));
      expect(entry, contains('[Desktop Action Extra]'));
      expect(
        entry.indexOf('$kAddedByKey='),
        lessThan(entry.indexOf('[Desktop Action Extra]')),
      );
    });

    test('records the version, replacing one already there', () {
      final entry = desktopEntryFor(
        sourceEntry.replaceFirst(
          'X-AppImage-Version=0.4.1',
          'X-AppImage-Version=0.4.1\n$kAddedBuildKey=1',
        ),
        appImagePath: '/a.AppImage',
        version: const AppVersion('0.4.1', 25),
      );
      expect(entry, contains('$kAddedVersionKey=0.4.1\n'));
      expect(entry.split('\n').where((l) => l.startsWith('$kAddedBuildKey=')), [
        '$kAddedBuildKey=25',
      ]);
    });

    test('a version cannot start a line of its own', () {
      final entry = desktopEntryFor(
        sourceEntry,
        appImagePath: '/a.AppImage',
        version: const AppVersion('0.4.1\nExec=/tmp/x\t\r', 25),
      );
      expect(
        entry,
        contains(
          '$kAddedVersionKey='
          r'0.4.1\nExec=/tmp/x\t\r'
          '\n',
        ),
      );
      expect(
        entry.split('\n').where((l) => l.startsWith('Exec=/tmp')),
        isEmpty,
      );
    });

    test('refuses a path with a line break', () {
      expect(
        () => desktopEntryFor(sourceEntry, appImagePath: '/a\nb'),
        throwsA(isA<FileSystemException>()),
      );
    });
  });
}
