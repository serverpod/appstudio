@Tags(['tool'])
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

/// Guards the one mistake in the release pipeline that cannot be undone.
///
/// Sparkle compares `CFBundleVersion` — the `+N` in pubspec.yaml — and the
/// published objects are immutable. A build number that repeats or goes
/// backwards makes every existing install permanently blind to updates, and
/// re-uploading cannot fix it. So the rule ("+N is a global counter that never
/// resets") is enforced in `tool/lib/pubspec_version.sh` and tested here rather
/// than left to a comment.
void main() {
  final root = Directory.current.path;
  final helper = p.join(root, 'tool', 'lib', 'pubspec_version.sh');
  final setVersion = p.join(root, 'tool', 'set_version.sh');

  late Directory tmp;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('version_gate');
  });

  tearDown(() async {
    if (await tmp.exists()) await tmp.delete(recursive: true);
  });

  /// Runs a snippet with the helper sourced. Returns (exitCode, stdout).
  Future<(int, String)> sh(String script) async {
    final result = await Process.run('/bin/bash', [
      '-c',
      'set -euo pipefail\nsource "$helper"\n$script',
    ]);
    return (result.exitCode, (result.stdout as String).trim());
  }

  /// Writes a pubspec with just enough in it to be parsed.
  Future<String> pubspecWith(String version) async {
    final file = File(p.join(tmp.path, 'pubspec.yaml'));
    await file.writeAsString('name: appstudio\nversion: $version\n');
    return file.path;
  }

  /// A feed on disk, reachable through curl's file:// support.
  ///
  /// Sparkle 2.9's `generate_appcast` writes the build number as a child
  /// ELEMENT. Getting this wrong is not a cosmetic bug: a parser that only
  /// understands the old attribute form reads every real feed as empty, so the
  /// gate returns 0 and silently permits a build number it should reject.
  /// Verified against actual `generate_appcast` output.
  Future<String> appcastWith(List<int> buildNumbers) async {
    final items = buildNumbers
        .map(
          (b) => '<item>\n'
              '<sparkle:version>$b</sparkle:version>\n'
              '<sparkle:shortVersionString>9.9.9</sparkle:shortVersionString>\n'
              '<enclosure url="https://example.com/a.zip"/>\n'
              '</item>',
        )
        .join('\n');
    final file = File(p.join(tmp.path, 'appcast.xml'));
    await file.writeAsString('<rss><channel>\n$items\n</channel></rss>');
    return 'file://${file.path}';
  }

  /// The pre-2.9 spelling, still accepted so an older feed keeps working.
  Future<String> legacyAppcastWith(List<int> buildNumbers) async {
    final items = buildNumbers
        .map(
          (b) => '<item><enclosure sparkle:version="$b" '
              'sparkle:shortVersionString="9.9.9"/></item>',
        )
        .join('\n');
    final file = File(p.join(tmp.path, 'legacy.xml'));
    await file.writeAsString('<rss><channel>\n$items\n</channel></rss>');
    return 'file://${file.path}';
  }

  group('read_pubspec_version', () {
    test('splits version and build', () async {
      final path = await pubspecWith('1.2.3+7');
      expect(await sh('read_pubspec_version "$path"'), (0, '1.2.3 7'));
    });

    test('a bare version reports build 0, so a bump lands on 1', () async {
      final path = await pubspecWith('1.2.3');
      expect(await sh('read_pubspec_version "$path"'), (0, '1.2.3 0'));
    });

    test('rejects a malformed version rather than guessing', () async {
      final path = await pubspecWith('1.2+7');
      final (code, _) = await sh('read_pubspec_version "$path"');
      expect(code, isNot(0));
    });
  });

  group('assert_build_is_newer', () {
    test('accepts a strictly higher build', () async {
      expect((await sh('assert_build_is_newer 8 7')).$1, 0);
    });

    test('rejects a repeat of the published build', () async {
      expect((await sh('assert_build_is_newer 7 7')).$1, isNot(0));
    });

    test('rejects a build that goes backwards', () async {
      expect((await sh('assert_build_is_newer 6 7')).$1, isNot(0));
    });

    test('accepts anything when nothing is published yet', () async {
      expect((await sh('assert_build_is_newer 1 0')).$1, 0);
    });
  });

  group('published_max_build', () {
    test('reads the highest sparkle:version element in the feed', () async {
      final url = await appcastWith([3, 11, 7]);
      expect(await sh('published_max_build "$url"'), (0, '11'));
    });

    test('still reads the pre-2.9 attribute spelling', () async {
      final url = await legacyAppcastWith([3, 11, 7]);
      expect(await sh('published_max_build "$url"'), (0, '11'));
    });

    test('a feed with items but no version reads as 0, not as a crash',
        () async {
      final file = File(p.join(tmp.path, 'bare.xml'));
      await file.writeAsString('<rss><channel><item/></channel></rss>');
      expect(
        await sh('published_max_build "file://${file.path}"'),
        (0, '0'),
      );
    });

    test('fails open on a missing feed, so the first release works', () async {
      expect(
        await sh('published_max_build "file:///nonexistent/appcast.xml"'),
        (0, '0'),
      );
    });
  });

  group('downloads_max_build', () {
    /// The downloads pointer, as publish_downloads.sh writes it.
    Future<String> downloadsWith({required int latest, required int preview}) async {
      final file = File(p.join(tmp.path, 'macos.json'));
      await file.writeAsString(
        '{"latest": {"build": $latest, "url": "https://x/a.zip"},'
        ' "preview": {"build": $preview, "url": "https://x/b.zip"}}',
      );
      return 'file://${file.path}';
    }

    test('reads the higher of latest and preview', () async {
      final url = await downloadsWith(latest: 7, preview: 9);
      expect(await sh('downloads_max_build "$url"'), (0, '9'));
    });

    test('fails open on a missing file', () async {
      expect(
        await sh('downloads_max_build "file:///nonexistent/macos.json"'),
        (0, '0'),
      );
    });

    test('unparseable JSON reads as 0, not as a crash', () async {
      final file = File(p.join(tmp.path, 'broken.json'));
      await file.writeAsString('not json');
      expect(
        await sh('downloads_max_build "file://${file.path}"'),
        (0, '0'),
      );
    });

    test('release_max_build takes the max of feed and downloads', () async {
      final feed = await appcastWith([7]);
      final downloads = await downloadsWith(latest: 7, preview: 12);
      expect(
        await sh('release_max_build "$feed" "$downloads"'),
        (0, '12'),
      );
      expect(
        await sh('release_max_build "$feed" "file:///nonexistent.json"'),
        (0, '7'),
      );
    });
  });

  group('set_version.sh', () {
    Future<(int, String, String)> run(
      String spec, {
      required String pubspec,
      required String appcastUrl,
      String downloadsUrl = 'file:///nonexistent/macos.json',
    }) async {
      final result = await Process.run(
        '/bin/bash',
        [setVersion, spec],
        environment: {
          'PUBSPEC': pubspec,
          'APPCAST_URL': appcastUrl,
          'DOWNLOADS_URL': downloadsUrl,
        },
      );
      return (
        result.exitCode,
        await File(pubspec).readAsString(),
        result.stderr as String,
      );
    }

    test('a minor bump carries the build counter forward', () async {
      final pubspec = await pubspecWith('1.0.0+7');
      final url = await appcastWith([7]);
      final (code, text, _) =
          await run('minor', pubspec: pubspec, appcastUrl: url);
      expect(code, 0);
      // The point of the whole exercise: 1.1.0+8, never 1.1.0+1.
      expect(text, contains('version: 1.1.0+8'));
    });

    test('clears a build number published from another checkout', () async {
      final pubspec = await pubspecWith('1.0.0+2');
      final url = await appcastWith([40]);
      final (code, text, _) =
          await run('patch', pubspec: pubspec, appcastUrl: url);
      expect(code, 0);
      expect(text, contains('version: 1.0.1+41'));
    });

    test('major and explicit versions still bump the counter', () async {
      final url = await appcastWith([7]);

      var pubspec = await pubspecWith('1.0.0+7');
      expect((await run('major', pubspec: pubspec, appcastUrl: url)).$2,
          contains('version: 2.0.0+8'));

      pubspec = await pubspecWith('1.0.0+7');
      expect((await run('3.1.4', pubspec: pubspec, appcastUrl: url)).$2,
          contains('version: 3.1.4+8'));
    });

    test('clears a build uploaded but not yet promoted', () async {
      // The split release flow's window: b9 is uploaded (so it is in the
      // downloads pointer) but not yet in the appcast. The next number must
      // clear it, or promoting both would repeat a CFBundleVersion.
      final pubspec = await pubspecWith('1.0.0+7');
      final feed = await appcastWith([7]);
      final downloads = File(p.join(tmp.path, 'pending.json'));
      await downloads.writeAsString(
        '{"latest": {"build": 7}, "preview": {"build": 9}}',
      );
      final (code, text, _) = await run(
        'patch',
        pubspec: pubspec,
        appcastUrl: feed,
        downloadsUrl: 'file://${downloads.path}',
      );
      expect(code, 0);
      expect(text, contains('version: 1.0.1+10'));
    });

    test('"build" republishes the same version under a new counter', () async {
      final pubspec = await pubspecWith('1.0.0+7');
      final url = await appcastWith([7]);
      final (code, text, _) =
          await run('build', pubspec: pubspec, appcastUrl: url);
      expect(code, 0);
      expect(text, contains('version: 1.0.0+8'));
    });

    test('refuses a version that goes backwards', () async {
      final pubspec = await pubspecWith('1.2.0+7');
      final url = await appcastWith([7]);
      final (code, text, err) =
          await run('1.1.0', pubspec: pubspec, appcastUrl: url);
      expect(code, isNot(0));
      expect(err, contains('older than'));
      expect(text, contains('version: 1.2.0+7'), reason: 'left untouched');
    });

    test('refuses a spec that is neither a version nor a keyword', () async {
      final pubspec = await pubspecWith('1.0.0+7');
      final url = await appcastWith([7]);
      final (code, text, _) =
          await run('1.2', pubspec: pubspec, appcastUrl: url);
      expect(code, isNot(0));
      expect(text, contains('version: 1.0.0+7'));
    });
  });
}
