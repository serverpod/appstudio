import 'dart:convert';

import 'package:appstudio/platform/host_platform.dart';
import 'package:appstudio/toolchain/tool_status.dart';
import 'package:appstudio/toolchain/tool_version.dart';
import 'package:appstudio/toolchain/toolchain_manifest.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/toolchain_support.dart';

void main() {
  Map<String, dynamic> valid() => {
        'schemaVersion': kManifestSchemaVersion,
        'tools': [
          {'id': 'command_line_tools'},
          {'id': 'flutter', 'accepts': '>=3.47.0'},
          {'id': 'serverpod_cli', 'accepts': '>=4.0.0 <4.1.0'},
        ],
      };

  test('parses the ranges', () {
    final manifest = ToolManifest.tryParse(jsonEncode(valid()))!;

    expect(
      manifest[ToolId.serverpodCli]!.accepts.allows(ToolVersion.tryParse('4.0.3')),
      isTrue,
    );
    expect(
      manifest[ToolId.serverpodCli]!.accepts.allows(ToolVersion.tryParse('4.1.0')),
      isFalse,
    );
    // No range means any version will do.
    expect(
      manifest[ToolId.commandLineTools]!.accepts.allows(ToolVersion.tryParse('1.0.0')),
      isTrue,
    );
  });

  group('avoid', () {
    Map<String, dynamic> serverpod(Object avoid) => {
          'id': 'serverpod_cli',
          'accepts': '>=4.1.0-beta.1 <5.0.0',
          'avoid': avoid,
        };

    test('keeps only the versions to avoid on this host', () {
      final json = serverpod({
        'windows': ['4.1.0-rc.1', '4.1.0'],
        'macos': ['4.1.1'],
      });
      expect(ToolSpec.tryParse(json, host: HostPlatform.windows)!.avoid, {
        ToolVersion.tryParse('4.1.0-rc.1'),
        ToolVersion.tryParse('4.1.0'),
      });
      expect(ToolSpec.tryParse(json, host: HostPlatform.macos)!.avoid,
          {ToolVersion.tryParse('4.1.1')});
    });

    test('is empty when the manifest has none', () {
      expect(ToolSpec.tryParse({'id': 'flutter'})!.avoid, isEmpty);
    });

    test('refuses a malformed version, even for another host', () {
      expect(
        ToolSpec.tryParse(
          serverpod({
            'windows': ['not a version'],
          }),
          host: HostPlatform.macos,
        ),
        isNull,
      );
      expect(ToolSpec.tryParse(serverpod(['4.1.0'])), isNull);
    });

  });

  test('falls back to the built-in display name', () {
    final manifest = ToolManifest.tryParse(jsonEncode(valid()))!;
    expect(manifest[ToolId.flutter]!.displayName, 'Flutter');
  });

  test('refuses another schema rather than half-reading it', () {
    // Schema 1 was the artifact manifest of builds that shipped their own
    // tools; its shape means something else entirely.
    final json = valid()..['schemaVersion'] = 1;
    expect(ToolManifest.tryParse(jsonEncode(json)), isNull);
  });

  test('refuses a manifest missing a tool', () {
    final json = valid();
    (json['tools'] as List).removeLast();
    expect(ToolManifest.tryParse(jsonEncode(json)), isNull);
  });

  test('refuses a malformed range instead of accepting everything', () {
    final json = valid();
    (json['tools'] as List)[1] = {'id': 'flutter', 'accepts': '>=three'};
    expect(ToolManifest.tryParse(jsonEncode(json)), isNull);
  });

  test('ignores an id this build does not know', () {
    final json = valid();
    (json['tools'] as List).add({'id': 'opencode', 'accepts': '>=1.0.0'});
    expect(ToolManifest.tryParse(jsonEncode(json)), isNotNull);
  });

  test('the bundled manifest covers every tool, on every host', () async {
    final source = await loadTestManifestSource();
    for (final host in [HostPlatform.macos, HostPlatform.windows]) {
      final manifest = ToolManifest.tryParse(source, host: host);
      expect(manifest, isNotNull, reason: '$host');
      expect(manifest!.tools.keys, ToolId.requiredOn(host), reason: '$host');
    }
  });

  test('the bundled Flutter range has no upper bound', () async {
    // Fresh installs take the latest stable and an old SDK is fixed with
    // `flutter upgrade`, which also goes to the latest stable. A ceiling would
    // put the two at odds the day a new minor ships.
    final manifest = await loadTestManifest();
    expect(
      manifest[ToolId.flutter]!.accepts.allows(ToolVersion.tryParse('99.0.0')),
      isTrue,
    );
  });
}
