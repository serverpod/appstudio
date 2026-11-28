import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:appstudio/platform/host_platform.dart';
import 'package:appstudio/platform/linux/desktop_integration.dart';
import 'package:appstudio/update/linux/appcast.dart';
import 'package:appstudio/update/linux/linux_updater.dart';
import 'package:cryptography/cryptography.dart';
import 'package:cryptography/dart.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

/// The Linux updater against a temporary folder and a fake HTTP server, so
/// it runs on any host. The signatures are real Ed25519 ones.
void main() {
  late Directory root;
  late String appImage;
  late String appDir;
  late Map<String, String> env;
  late SimpleKeyPair keys;
  late String publicKey;
  late AppVersion running;

  /// What the fake server serves: the feed, and the files by URL path.
  late String feedBody;
  late Map<String, List<int>> files;
  late int feedStatus;

  final newer = utf8.encode('#!/bin/sh\necho the newer build\n');

  Future<String> sign(List<int> bytes) async =>
      base64.encode((await DartEd25519().sign(bytes, keyPair: keys)).bytes);

  Future<String> feedFor(
    List<int> bytes, {
    int build = 26,
    int? length,
    String? signature,
  }) async =>
      '''
<rss xmlns:sparkle="$kSparkleNamespace"><channel><item>
  <enclosure url="https://updates.test/AppStudio-0.4.2.AppImage"
    sparkle:version="$build" sparkle:shortVersionString="0.4.2"
    sparkle:os="linux-x86_64"
    sparkle:edSignature="${signature ?? await sign(bytes)}"
    length="${length ?? bytes.length}" />
</item></channel></rss>''';

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    running = const AppVersion('0.4.1', 25);
    root = await Directory.systemTemp.createTemp('linux_updater');
    appDir = p.join(root.path, 'mount');
    appImage = p.join(root.path, 'AppImages', 'AppStudio-x86_64.AppImage');
    await File(appImage).create(recursive: true);
    await File(appImage).writeAsString('the running build');
    env = {
      'HOME': p.join(root.path, 'home'),
      'APPIMAGE': appImage,
      'APPDIR': appDir,
      'XDG_DATA_DIRS': p.join(root.path, 'system'),
    };
    keys = await DartEd25519().newKeyPair();
    publicKey = base64.encode((await keys.extractPublicKey()).bytes);
    files = {'/AppStudio-0.4.2.AppImage': newer};
    feedStatus = 200;
    feedBody = await feedFor(newer);
  });

  tearDown(() => root.delete(recursive: true));

  http.Client client() => MockClient.streaming((request, _) async {
    if (request.url.path == '/appcast.xml') {
      return http.StreamedResponse(
        Stream.value(utf8.encode(feedBody)),
        feedStatus,
      );
    }
    final body = files[request.url.path];
    if (body == null) return http.StreamedResponse(const Stream.empty(), 404);
    // In chunks, as a real download arrives.
    return http.StreamedResponse(
      Stream.fromIterable([
        for (var i = 0; i < body.length; i += 8)
          body.sublist(i, i + 8 > body.length ? body.length : i + 8),
      ]),
      200,
    );
  });

  LinuxUpdater updater({
    LinuxUpdateConfig? config,
    Map<String, String>? environment,
    http.Client? httpClient,
  }) {
    final e = environment ?? env;
    final executable = p.join(appDir, 'usr', 'lib', 'appstudio', 'appstudio');
    return LinuxUpdater(
      config:
          config ??
          LinuxUpdateConfig(
            appcastUrl: 'https://updates.test/appcast.xml',
            publicKey: publicKey,
          ),
      environment: e,
      executable: executable,
      client: httpClient ?? client(),
      runningVersion: () async => running,
      desktop: DesktopIntegration(
        environment: e,
        host: HostPlatform.linux,
        executable: executable,
        runningVersion: () async => running,
      ),
    );
  }

  String part() => p.join(p.dirname(appImage), LinuxUpdater.partName);

  /// App Studio's own menu entry, naming [file] and recording [version].
  Future<void> writeOwnEntry(String file, AppVersion version) async {
    final entry = File(
      p.join(
        env['HOME']!,
        '.local',
        'share',
        'applications',
        'dev.serverpod.appstudio.desktop',
      ),
    );
    await entry.create(recursive: true);
    await entry.writeAsString(
      '[Desktop Entry]\nName=App Studio\nTryExec=$file\n'
      'X-AppStudio-AddedBy=appstudio\n'
      'X-AppStudio-Version=${version.version}\n'
      'X-AppStudio-Build=${version.build}\n',
    );
  }

  group('state', () {
    test('is configured as an AppImage with a feed and a key', () async {
      final state = await updater().state();
      expect(state.canCheck, isTrue);
      expect(state.currentVersion, '0.4.1');
      expect(state.currentBuild, '25');
      expect(state.automaticallyChecks, isTrue, reason: 'on by default');
    });

    test('is not without a feed or a key', () async {
      for (final config in const [
        LinuxUpdateConfig(appcastUrl: '', publicKey: 'k'),
        LinuxUpdateConfig(appcastUrl: 'https://x', publicKey: ''),
      ]) {
        expect((await updater(config: config).state()).canCheck, isFalse);
      }
    });

    test('is not outside an AppImage, but still knows the version', () async {
      final state = await updater(environment: const {}).state();
      expect(state.canCheck, isFalse);
      expect(state.currentVersion, '0.4.1');
    });

    test('remembers automatic checks switched off', () async {
      await updater().setAutomaticallyChecks(false);
      expect((await updater().state()).automaticallyChecks, isFalse);
    });
  });

  group('check', () {
    test('finds the newer build and records the check', () async {
      final update = await updater().check();
      expect(update!.version, const AppVersion('0.4.2', 26));
      expect((await updater().state()).lastCheck, isNotNull);
    });

    test('finds nothing when this is the newest', () async {
      running = const AppVersion('0.4.2', 26);
      expect(await updater().check(), isNull);
    });

    test('says why a feed cannot be read', () async {
      feedStatus = 404;
      await expectLater(
        updater().check(),
        throwsA(
          isA<LinuxUpdateException>().having(
            (e) => e.message,
            'message',
            contains('404'),
          ),
        ),
      );
      feedStatus = 200;
      feedBody = '<html>';
      await expectLater(
        updater().check(),
        throwsA(isA<LinuxUpdateException>()),
      );
      expect(
        (await updater().state()).lastCheck,
        isNotNull,
        reason: 'a failing feed is not asked again every hour',
      );
    });

    test('refuses a feed over plain http', () async {
      await expectLater(
        updater(
          config: LinuxUpdateConfig(
            appcastUrl: 'http://updates.example.com/appcast.xml',
            publicKey: publicKey,
          ),
        ).check(),
        throwsA(
          isA<LinuxUpdateException>().having(
            (e) => e.message,
            'message',
            contains('https'),
          ),
        ),
      );
    });

    test('clears a download an earlier run left behind', () async {
      await File(part()).writeAsString('half a download');
      await updater().check();
      expect(await File(part()).exists(), isFalse);
    });

    test('refuses to run without a feed', () async {
      await expectLater(
        updater(
          config: const LinuxUpdateConfig(appcastUrl: '', publicKey: ''),
        ).check(),
        throwsA(isA<LinuxUpdateException>()),
      );
    });
  });

  group('is a check due', () {
    test('when there was none, or the last is a day old', () async {
      final now = DateTime.now();
      expect(await updater().isCheckDue(now), isTrue);
      await updater().check();
      expect(await updater().isCheckDue(now), isFalse);
      expect(
        await updater().isCheckDue(
          now.add(const Duration(days: 1, minutes: 1)),
        ),
        isTrue,
      );
    });

    test('never with automatic checks off', () async {
      await updater().setAutomaticallyChecks(false);
      expect(await updater().isCheckDue(DateTime.now()), isFalse);
    });
  });

  group('download', () {
    Future<AppcastItem> item() async => (await updater().check())!;

    test('writes a checked, executable file beside the AppImage', () async {
      final progress = <int>[];
      final verified = await updater().download(
        await item(),
        onProgress: (received, _) => progress.add(received),
      );

      expect(verified!.path, part());
      expect(await File(part()).readAsBytes(), newer);
      expect(progress.last, newer.length);
      if (!Platform.isWindows) {
        expect((await File(part()).stat()).modeString(), 'rwxr-xr-x');
      }
      expect(await File(appImage).readAsString(), 'the running build');
    });

    test('refuses a file with another signature, and deletes it', () async {
      feedBody = await feedFor(
        newer,
        signature: await sign(utf8.encode('something else')),
      );
      await expectLater(
        updater().download(await item()),
        throwsA(
          isA<LinuxUpdateException>().having(
            (e) => e.message,
            'message',
            contains('signature'),
          ),
        ),
      );
      expect(await File(part()).exists(), isFalse);
    });

    test('refuses a file signed with another key', () async {
      final other = await DartEd25519().newKeyPair();
      feedBody = await feedFor(
        newer,
        signature: base64.encode(
          (await DartEd25519().sign(newer, keyPair: other)).bytes,
        ),
      );
      await expectLater(
        updater().download(await item()),
        throwsA(isA<LinuxUpdateException>()),
      );
    });

    test('refuses a download over plain http', () async {
      final insecure = AppcastItem(
        version: const AppVersion('0.4.2', 26),
        url: Uri.parse('http://updates.example.com/AppStudio.AppImage'),
        length: newer.length,
        signature: await sign(newer),
      );
      await expectLater(
        updater().download(insecure),
        throwsA(isA<LinuxUpdateException>()),
      );
      expect(await File(part()).exists(), isFalse);
    });

    test('does not write through a link left in its place', () async {
      if (Platform.isWindows) return;
      final elsewhere = p.join(root.path, 'elsewhere');
      await File(elsewhere).writeAsString('not ours to change');
      await Link(part()).create(elsewhere);

      await updater().download(await item());

      expect(await File(elsewhere).readAsString(), 'not ours to change');
      expect(await File(part()).readAsBytes(), newer);
    });

    test('runs one download at a time, and a check leaves it alone', () async {
      final u = updater();
      final first = (await u.check())!;
      var checkedDuring = false;
      final verified = await u.download(
        first,
        onProgress: (received, _) async {
          if (checkedDuring) return;
          checkedDuring = true;
          // The menu stays usable under the dialog: a second download is
          // refused, and a check must not delete this one's file.
          await expectLater(
            u.download(first),
            throwsA(isA<LinuxUpdateException>()),
          );
          await u.check();
          expect(await File(part()).exists(), isTrue);
        },
      );
      expect(checkedDuring, isTrue);
      expect(verified, isNotNull);
      expect(await File(part()).readAsBytes(), newer);
    });

    test('refuses a file of another length', () async {
      feedBody = await feedFor(newer, length: newer.length + 1);
      await expectLater(
        updater().download(await item()),
        throwsA(
          isA<LinuxUpdateException>().having(
            (e) => e.message,
            'message',
            contains('bytes'),
          ),
        ),
      );
      expect(await File(part()).exists(), isFalse);
    });

    test('stops when cancelled, and deletes what it wrote', () async {
      final cancellation = UpdateCancellation();
      final verified = await updater().download(
        await item(),
        cancellation: cancellation,
        onProgress: (_, _) => cancellation.cancel(),
      );
      expect(verified, isNull);
      expect(await File(part()).exists(), isFalse);
    });

    test(
      'stops at once when cancelled while the server sends nothing',
      () async {
        // One chunk, then silence: the stream never ends, and the download
        // would otherwise wait out its 60 s timeout and report a failure.
        final stalled = StreamController<List<int>>();
        addTearDown(stalled.close);
        stalled.add(newer.sublist(0, 8));
        final cancellation = UpdateCancellation();
        final verified =
            await updater(
                  httpClient: MockClient.streaming(
                    (_, _) async => http.StreamedResponse(stalled.stream, 200),
                  ),
                )
                .download(
                  await item(),
                  cancellation: cancellation,
                  onProgress: (_, _) => Timer(
                    const Duration(milliseconds: 50),
                    cancellation.cancel,
                  ),
                )
                .timeout(const Duration(seconds: 5));
        expect(verified, isNull);
        expect(await File(part()).exists(), isFalse);
      },
    );

    test('stops at once when cancelled while connecting', () async {
      final never = Completer<http.StreamedResponse>();
      final cancellation = UpdateCancellation();
      Timer(const Duration(milliseconds: 50), cancellation.cancel);
      final verified =
          await updater(
                httpClient: MockClient.streaming((_, _) => never.future),
              )
              .download(await item(), cancellation: cancellation)
              .timeout(const Duration(seconds: 5));
      expect(verified, isNull);
      expect(await File(part()).exists(), isFalse);

      // The response turns up after all: its body is let go, so the
      // connection does not stay open.
      final body = StreamController<List<int>>();
      final released = Completer<void>();
      body.onCancel = released.complete;
      body.onListen = () {};
      never.complete(http.StreamedResponse(body.stream, 200));
      await released.future.timeout(const Duration(seconds: 5));
    });

    test('says so where the AppImage cannot be replaced', () async {
      if (Platform.isWindows) return;
      final uid = await Process.run('id', ['-u']);
      if ('${uid.stdout}'.trim() == '0') {
        markTestSkipped('root can write anywhere');
        return;
      }
      final folder = p.dirname(appImage);
      await Process.run('chmod', ['555', folder]);
      addTearDown(() => Process.run('chmod', ['755', folder]));

      await expectLater(
        updater().download(await item()),
        throwsA(
          isA<LinuxUpdateException>().having(
            (e) => e.message,
            'message',
            contains('cannot replace itself'),
          ),
        ),
      );
    }, tags: 'process');
  });

  group('install', () {
    test(
      'replaces the AppImage and starts it once this process has ended',
      () async {
        final marker = p.join(root.path, 'started');
        files['/AppStudio-0.4.2.AppImage'] = utf8.encode(
          '#!/bin/sh\necho started > "$marker"\n',
        );
        feedBody = await feedFor(files['/AppStudio-0.4.2.AppImage']!);
        final u = updater();
        final verified = await u.download((await u.check())!);
        final ended = await Process.start('true', []);
        await ended.exitCode;

        await u.install(verified!, afterPid: ended.pid);

        expect(await File(part()).exists(), isFalse);
        expect(await File(appImage).readAsString(), contains('started'));
        final end = DateTime.now().add(const Duration(seconds: 5));
        while (!await File(marker).exists() && DateTime.now().isBefore(end)) {
          await Future<void>.delayed(const Duration(milliseconds: 50));
        }
        expect(await File(marker).exists(), isTrue);
      },
      tags: 'process',
      testOn: '!windows',
    );

    test(
      'records the new version in App Studio\'s menu entry',
      () async {
        final entry = File(
          p.join(
            env['HOME']!,
            '.local',
            'share',
            'applications',
            'dev.serverpod.appstudio.desktop',
          ),
        );
        await entry.create(recursive: true);
        await entry.writeAsString(
          '[Desktop Entry]\nName=App Studio\nTryExec=$appImage\n'
          'X-AppStudio-AddedBy=appstudio\nX-AppStudio-Version=0.4.1\n'
          'X-AppStudio-Build=25\n',
        );
        final u = updater();
        final verified = await u.download((await u.check())!);
        final ended = await Process.start('true', []);
        await ended.exitCode;

        await u.install(verified!, afterPid: ended.pid);

        final keys = parseDesktopEntry(await entry.readAsString());
        expect(keys['X-AppStudio-Version'], '0.4.2');
        expect(keys['X-AppStudio-Build'], '26');
      },
      tags: 'process',
      testOn: '!windows',
    );
  });

  group('after Add to Applications in the same run', () {
    test('never takes another file it finds in ~/AppImages', () async {
      // The started copy was deleted, not moved; a newer one sits in
      // ~/AppImages, left there after Remove. It is not this App Studio.
      final other = p.join(
        env['HOME']!,
        'AppImages',
        'AppStudio-x86_64.AppImage',
      );
      await File(other).create(recursive: true);
      await writeOwnEntry(other, const AppVersion('0.4.3', 27));
      await File(appImage).delete();

      expect(await updater().liveAppImage(), isNull);
    });

    test(
      'replaces the file in ~/AppImages, not where it was started from',
      () async {
        // Add moved the running file; `$APPIMAGE` still names the old place.
        final added = p.join(
          env['HOME']!,
          'AppImages',
          'AppStudio-x86_64.AppImage',
        );
        await File(added).create(recursive: true);
        await File(appImage).rename(added);
        await writeOwnEntry(added, running);
        final u = updater();

        expect(await u.liveAppImage(), added);
        final verified = await u.download((await u.check())!);
        expect(p.dirname(verified!.path), p.dirname(added));
        final ended = await Process.start('true', []);
        await ended.exitCode;
        await u.install(verified, afterPid: ended.pid);

        expect(await File(added).readAsBytes(), newer);
        expect(await File(appImage).exists(), isFalse);
      },
      tags: 'process',
      testOn: '!windows',
    );
  });

  group('after Add copied rather than moved', () {
    test('clears a leftover download beside either copy', () async {
      final added = p.join(
        env['HOME']!,
        'AppImages',
        'AppStudio-x86_64.AppImage',
      );
      await File(added).create(recursive: true);
      await writeOwnEntry(added, running);
      final besideStarted = File(part());
      final besideAdded = File(p.join(p.dirname(added), LinuxUpdater.partName));
      await besideStarted.writeAsString('half a download');
      await besideAdded.writeAsString('half a download');

      await updater().check();

      expect(await besideStarted.exists(), isFalse);
      expect(await besideAdded.exists(), isFalse);
    });

    test(
      'replaces the copy in ~/AppImages, not the original left behind',
      () async {
        // Add could not take the file out of its folder (/opt, say), so it
        // copied it; the original is still where `$APPIMAGE` names it.
        final added = p.join(
          env['HOME']!,
          'AppImages',
          'AppStudio-x86_64.AppImage',
        );
        await File(added).create(recursive: true);
        await File(appImage).copy(added);
        await writeOwnEntry(added, running);
        final original = await File(appImage).readAsBytes();
        final u = updater();

        expect(await u.liveAppImage(), added);
        final verified = await u.download((await u.check())!);
        expect(p.dirname(verified!.path), p.dirname(added));
        final ended = await Process.start('true', []);
        await ended.exitCode;
        await u.install(verified, afterPid: ended.pid);

        expect(await File(added).readAsBytes(), newer);
        expect(await File(appImage).readAsBytes(), original);
      },
      tags: 'process',
      testOn: '!windows',
    );

    test(
      'replaces the started file when the menu\'s copy is another build',
      () async {
        final added = p.join(
          env['HOME']!,
          'AppImages',
          'AppStudio-x86_64.AppImage',
        );
        await File(added).create(recursive: true);
        await writeOwnEntry(added, const AppVersion('0.4.0', 24));

        expect(await updater().liveAppImage(), appImage);
      },
    );
  });

  group('verifyEd25519File', () {
    test(
      'accepts what openssl signs, as the release pipeline does',
      () async {
        final openssl = await Process.run('which', ['openssl']);
        if (openssl.exitCode != 0) {
          markTestSkipped('needs openssl');
          return;
        }
        final key = p.join(root.path, 'key.pem');
        final file = p.join(root.path, 'file');
        await File(file).writeAsBytes(newer);
        await Process.run('openssl', [
          'genpkey',
          '-algorithm',
          'ed25519',
          '-out',
          key,
        ]);
        final sig = p.join(root.path, 'sig');
        await Process.run('openssl', [
          'pkeyutl',
          '-sign',
          '-inkey',
          key,
          '-rawin',
          '-in',
          file,
          '-out',
          sig,
        ]);
        final der = await Process.run('openssl', [
          'pkey',
          '-in',
          key,
          '-pubout',
          '-outform',
          'DER',
        ], stdoutEncoding: null);
        final derBytes = der.stdout as List<int>;
        final public = base64.encode(derBytes.sublist(derBytes.length - 32));
        final signature = base64.encode(await File(sig).readAsBytes());

        expect(await verifyEd25519File(file, signature, public), isTrue);
        await File(file).writeAsString('changed');
        expect(await verifyEd25519File(file, signature, public), isFalse);
      },
      tags: 'process',
      testOn: '!windows',
    );

    test('rejects a malformed signature or key', () async {
      final file = p.join(root.path, 'file');
      await File(file).writeAsBytes(newer);
      expect(await verifyEd25519File(file, 'not base64!', publicKey), isFalse);
      expect(
        await verifyEd25519File(file, base64.encode([1]), publicKey),
        isFalse,
      );
    });
  });
}
