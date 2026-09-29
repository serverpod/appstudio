import 'dart:convert';

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

  test('the bundled manifest parses and covers every tool', () async {
    final manifest = await loadTestManifest();
    expect(manifest.tools.keys, containsAll(ToolId.values));
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
