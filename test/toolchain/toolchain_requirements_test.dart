import 'dart:convert';
import 'dart:io';

import 'package:appstudio/toolchain/tool_status.dart';
import 'package:appstudio/toolchain/tool_version.dart';
import 'package:appstudio/toolchain/toolchain_manifest.dart';
import 'package:appstudio/toolchain/toolchain_requirements.dart';
import 'package:flutter_test/flutter_test.dart';

ToolVersion v(String s) => ToolVersion.tryParse(s)!;

/// The real Serverpod spec: >=4.0.0-beta.1 <4.1.0.
late ToolSpec serverpod;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    final manifest = ToolManifest.tryParse(
      await File('assets/toolchain_manifest.json').readAsString(),
    )!;
    serverpod = manifest[ToolId.serverpodCli]!;
  });

  group('defaults', () {
    test('falls back to the manifest range when nothing is overridden', () {
      const req = ToolchainRequirements.empty;
      expect(req.effectiveMinimum(serverpod).toString(), '4.0.0-beta.1');
      expect(req.accepts(serverpod, v('4.0.0-beta.1')), isTrue);
      expect(req.accepts(serverpod, v('4.0.0')), isTrue);
      expect(req.accepts(serverpod, v('3.5.0-beta.7')), isFalse);
      expect(req.accepts(serverpod, null), isFalse);
    });
  });

  group('user overrides', () {
    test('a higher minimum is honoured', () {
      final req = ToolchainRequirements.empty
          .withMinimum(ToolId.serverpodCli, v('4.0.0-beta.5'));
      expect(req.effectiveMinimum(serverpod).toString(), '4.0.0-beta.5');
      expect(req.accepts(serverpod, v('4.0.0-beta.5')), isTrue);
      expect(req.accepts(serverpod, v('4.0.0-beta.1')), isFalse);
    });

    test('a lower minimum cannot weaken the manifest floor', () {
      // Letting a user drop below what this build was tested against would
      // admit an untested CLI and produce unexplainable failures.
      final req = ToolchainRequirements.empty
          .withMinimum(ToolId.serverpodCli, v('3.0.0'));
      expect(req.effectiveMinimum(serverpod).toString(), '4.0.0-beta.1');
      expect(req.accepts(serverpod, v('3.5.0-beta.7')), isFalse);
    });

    test('the manifest upper bound still applies', () {
      final req = ToolchainRequirements.empty
          .withMinimum(ToolId.serverpodCli, v('4.0.0'));
      expect(req.accepts(serverpod, v('4.1.0')), isFalse);
    });

    test('clearing an override restores the default', () {
      final req = ToolchainRequirements.empty
          .withMinimum(ToolId.serverpodCli, v('4.0.0-beta.5'))
          .withMinimum(ToolId.serverpodCli, null);
      expect(req.userMinimumFor(ToolId.serverpodCli), isNull);
      expect(req.effectiveMinimum(serverpod).toString(), '4.0.0-beta.1');
    });

    test('describe shows the raised floor', () {
      expect(
        ToolchainRequirements.empty.describe(serverpod),
        '>=4.0.0-beta.1 <4.1.0',
      );
      expect(
        ToolchainRequirements.empty
            .withMinimum(ToolId.serverpodCli, v('4.0.0-beta.5'))
            .describe(serverpod),
        '>=4.0.0-beta.5 <4.1.0',
      );
    });
  });

  group('persistence', () {
    test('round-trips through JSON', () {
      final req = ToolchainRequirements.empty
          .withMinimum(ToolId.serverpodCli, v('4.0.0-beta.5'))
          .withMinimum(ToolId.flutter, v('3.44.2'));
      final restored = ToolchainRequirements.fromJson(
        jsonEncode(req.toJson()),
      );
      expect(restored.userMinimumFor(ToolId.serverpodCli).toString(),
          '4.0.0-beta.5');
      expect(restored.userMinimumFor(ToolId.flutter).toString(), '3.44.2');
    });

    test('a corrupt or foreign file degrades to defaults, never throws', () {
      for (final bad in [
        '',
        'not json',
        '{}',
        '[]',
        '{"schemaVersion": 99, "tools": {"flutter": {"minVersion": "9.0.0"}}}',
        '{"schemaVersion": 1, "tools": "nope"}',
        '{"schemaVersion": 1, "tools": {"flutter": {"minVersion": "garbage"}}}',
        '{"schemaVersion": 1, "tools": {"unknown-tool": {"minVersion": "1.0.0"}}}',
      ]) {
        final req = ToolchainRequirements.fromJson(bad);
        expect(req.userMinimumFor(ToolId.flutter), isNull, reason: bad);
      }
    });

    test('load returns defaults when the file is missing', () async {
      final missing =
          '${Directory.systemTemp.path}/appstudio-no-such-requirements.json';
      final req = await ToolchainRequirements.load(missing);
      expect(req.userMinimumFor(ToolId.flutter), isNull);
    });

    test('saves and reloads from disk', () async {
      final dir = await Directory.systemTemp.createTemp('appstudio_req');
      addTearDown(() => dir.delete(recursive: true));
      final path = '${dir.path}/requirements.json';

      await ToolchainRequirements.empty
          .withMinimum(ToolId.opencode, v('1.19.0'))
          .save(path);
      final restored = await ToolchainRequirements.load(path);

      expect(restored.userMinimumFor(ToolId.opencode).toString(), '1.19.0');
    });
  });
}
