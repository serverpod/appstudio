import 'dart:convert';

import 'package:appstudio/toolchain/install_plan.dart';
import 'package:appstudio/toolchain/tool_version.dart';
import 'package:flutter_test/flutter_test.dart';

/// Shaped like the real responses, trimmed to what matters.
void main() {
  group('pickFlutterRelease', () {
    Map<String, dynamic> release(
      String version, {
      String channel = 'stable',
      String? arch = 'arm64',
    }) =>
        {
          'hash': 'x',
          'channel': channel,
          'version': version,
          'dart_sdk_arch': ?arch,
          'archive': '$channel/macos/flutter_macos_${arch}_$version-$channel.zip',
          'sha256': 'ABC$version',
        };

    String feed(List<Map<String, dynamic>> releases) => jsonEncode({
          'base_url': 'https://storage.googleapis.com/flutter_infra_release/releases',
          'releases': releases,
        });

    final any = VersionRange.tryParse('>=3.47.0')!;

    test('takes the newest stable release for this architecture', () {
      final picked = pickFlutterRelease(
        feed([
          release('3.47.4'),
          release('3.47.5', arch: 'x64'),
          release('3.48.0-0.1.pre', channel: 'beta'),
          release('3.47.3'),
        ]),
        accepts: any,
        arch: 'arm64',
      )!;

      expect(picked.version.toString(), '3.47.4');
      expect(
        picked.archiveUrl.toString(),
        'https://storage.googleapis.com/flutter_infra_release/releases/'
        'stable/macos/flutter_macos_arm64_3.47.4-stable.zip',
      );
      expect(picked.sha256, 'abc3.47.4');
    });

    test('respects the range', () {
      final picked = pickFlutterRelease(
        feed([release('3.46.0'), release('3.47.0')]),
        accepts: VersionRange.tryParse('<3.47.0')!,
        arch: 'arm64',
      );
      expect(picked!.version.toString(), '3.46.0');
    });

    test('treats entries without an arch as x64', () {
      // The oldest entries predate per-arch archives.
      final picked = pickFlutterRelease(
        feed([release('3.47.1', arch: null)]),
        accepts: any,
        arch: 'arm64',
      );
      expect(picked, isNull);
    });

    test('garbage yields nothing', () {
      expect(pickFlutterRelease('nope', accepts: any, arch: 'arm64'), isNull);
    });
  });

  group('pickPubVersion', () {
    String listing(List<(String, bool)> versions) => jsonEncode({
          'versions': [
            for (final (v, retracted) in versions)
              {'version': v, if (retracted) 'retracted': true},
          ],
        });

    final range = VersionRange.tryParse('>=4.0.0 <4.1.0')!;

    test('takes the newest stable version inside the range', () {
      expect(
        pickPubVersion(
          listing([
            ('4.0.0', false),
            ('4.0.3', false),
            ('4.0.4', true),
            ('4.1.0-beta.1', false),
            ('4.1.0', false),
          ]),
          range,
        ).toString(),
        '4.0.3',
      );
    });

    test('falls back to a prerelease when that is all there is', () {
      expect(
        pickPubVersion(listing([('4.0.0-rc.2', false)]),
                VersionRange.tryParse('>=4.0.0-rc.1')!)
            .toString(),
        '4.0.0-rc.2',
      );
    });

    test('nothing in range yields nothing', () {
      expect(pickPubVersion(listing([('3.4.1', false)]), range), isNull);
    });
  });
}
