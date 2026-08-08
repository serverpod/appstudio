import 'dart:convert';
import 'dart:io';

import 'package:appstudio/toolchain/tool_status.dart';
import 'package:appstudio/toolchain/tool_version.dart';
import 'package:appstudio/toolchain/platform_key.dart';
import 'package:appstudio/toolchain/toolchain_manifest.dart';
import 'package:flutter_test/flutter_test.dart';

/// A manifest with one fully-published tool, matching what
/// tool/publish_toolchain.sh emits.
String published({
  String schemaVersion = '1',
  String platformKey = 'macos-arm64',
}) =>
    '''
{
  "schemaVersion": $schemaVersion,
  "manifestId": "2026.08.0",
  "baseUrl": "https://storage.googleapis.com/serverpod-appstudio-toolchain/",
  "tools": [
    {
      "id": "flutter",
      "displayName": "Flutter SDK",
      "version": "3.44.2",
      "build": 1,
      "hostAccepts": ">=3.44.0 <3.45.0",
      "required": true,
      "installDir": "flutter/3.44.2",
      "platforms": {
        "$platformKey": {
          "path": "tools/flutter/3.44.2+1/flutter-web-macos-arm64-3.44.2+1.tar.gz",
          "sha256": "9F8C0000000000000000000000000000000000000000000000000000000000AB",
          "downloadBytes": 812345678,
          "installedBytes": 1610612736,
          "format": "tar.gz",
          "stripComponents": 1
        }
      },
      "entrypoints": {"flutter": "bin/flutter"},
      "metadata": {"channel": "stable"}
    }
  ]
}
''';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('parse', () {
    test('reads a published tool', () {
      final manifest = ToolManifest.tryParse(published())!;
      expect(manifest.manifestId, '2026.08.0');

      final flutter = manifest[ToolId.flutter]!;
      expect(flutter.version.toString(), '3.44.2');
      expect(flutter.required, isTrue);
      expect(flutter.hostAccepts.allows(ToolVersion.tryParse('3.44.2')), isTrue);
      expect(flutter.hostAccepts.allows(ToolVersion.tryParse('3.38.0')), isFalse);
      expect(flutter.entrypoints['flutter'], 'bin/flutter');
      expect(flutter.metadata['channel'], 'stable');
    });

    test('lowercases the hash so comparison is case-insensitive', () {
      final artifact =
          ToolManifest.tryParse(published())![ToolId.flutter]!.platforms.values.first;
      expect(artifact.sha256, startsWith('9f8c'));
      expect(artifact.downloadBytes, 812345678);
      expect(artifact.installedBytes, 1610612736);
      expect(artifact.stripComponents, 1);
    });

    test('resolves an artifact URL against the base', () {
      final manifest = ToolManifest.tryParse(published())!;
      final artifact = manifest[ToolId.flutter]!.platforms.values.first;
      expect(
        manifest.urlFor(artifact).toString(),
        'https://storage.googleapis.com/serverpod-appstudio-toolchain/'
        'tools/flutter/3.44.2+1/flutter-web-macos-arm64-3.44.2+1.tar.gz',
      );
    });

    test('rejects a newer schema instead of half-reading it', () {
      expect(ToolManifest.tryParse(published(schemaVersion: '2')), isNull);
    });

    test('rejects malformed input rather than throwing', () {
      for (final bad in ['', 'not json', '{}', '[]', '{"schemaVersion": 1}']) {
        expect(ToolManifest.tryParse(bad), isNull, reason: 'input: $bad');
      }
    });

    test('ignores unknown tool ids so a newer manifest still loads', () {
      final json = jsonDecode(published()) as Map<String, dynamic>;
      (json['tools'] as List).add({
        'id': 'some-future-tool',
        'version': '1.0.0',
        'hostAccepts': '*',
      });
      final manifest = ToolManifest.tryParse(jsonEncode(json))!;
      expect(manifest.tools.keys, [ToolId.flutter]);
    });

    test('drops a tool whose version range is a typo', () {
      // A permissive fallback would silently accept every host version.
      final json = jsonDecode(published()) as Map<String, dynamic>;
      (json['tools'] as List)[0]['hostAccepts'] = '>=not.a.version';
      expect(ToolManifest.tryParse(jsonEncode(json)), isNull);
    });
  });

  group('platform selection', () {
    test('reports no artifact when this platform was not published', () {
      final manifest =
          ToolManifest.tryParse(published(platformKey: 'linux-x64'))!;
      expect(manifest[ToolId.flutter]!.artifactForCurrentPlatform, isNull);
    });

    test('current key is a macOS arch', () {
      expect(currentPlatformKey(), anyOf('macos-arm64', 'macos-x64'));
    });
  });

  group('baked asset', () {
    test('assets/toolchain_manifest.json parses and covers every tool', () async {
      // Read from disk rather than rootBundle so a broken asset declaration
      // cannot make this pass by accident.
      final source =
          await File('assets/toolchain_manifest.json').readAsString();
      final manifest = ToolManifest.tryParse(source);
      expect(manifest, isNotNull, reason: 'baked manifest must be valid');
      expect(manifest!.tools.keys.toSet(), ToolId.values.toSet());
    });

    test('pins match toolchain/active.json', () async {
      final source =
          await File('assets/toolchain_manifest.json').readAsString();
      final manifest = ToolManifest.tryParse(source)!;
      final active = jsonDecode(
        await File('toolchain/active.json').readAsString(),
      ) as Map<String, dynamic>;

      expect(manifest[ToolId.flutter]!.version.toString(), active['flutter']);
      expect(
        manifest[ToolId.serverpodCli]!.version.toString(),
        active['serverpod_cli'],
      );
      expect(manifest[ToolId.opencode]!.version.toString(), active['opencode']);
      expect(manifest[ToolId.git]!.version.toString(), active['git']);
    });

    test('every published artifact has a real hash and size', () async {
      // Guards against shipping a placeholder hash the installer would then
      // verify against, or a zero size that would break the preflight total.
      final source =
          await File('assets/toolchain_manifest.json').readAsString();
      final manifest = ToolManifest.tryParse(source)!;

      for (final spec in manifest.tools.values) {
        for (final entry in spec.platforms.entries) {
          final artifact = entry.value;
          final where = '${spec.id.manifestId}/${entry.key}';
          expect(artifact.sha256, hasLength(64), reason: '$where sha256');
          expect(
            RegExp(r'^[0-9a-f]{64}$').hasMatch(artifact.sha256),
            isTrue,
            reason: '$where sha256 must be hex',
          );
          expect(artifact.downloadBytes, greaterThan(0), reason: '$where size');
          expect(artifact.installedBytes, greaterThan(0), reason: '$where size');
          expect(artifact.path, isNotEmpty, reason: '$where path');
        }
      }
    });
  });
}
