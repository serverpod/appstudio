import 'dart:io';

import 'package:appstudio/toolchain/install_record.dart';
import 'package:appstudio/toolchain/tool_status.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  final at = DateTime.utc(2026, 9, 28, 12);
  final flutter = RecordedInstall(
    id: ToolId.flutter,
    path: '/Users/alex/develop/flutter',
    version: '3.47.5',
    installedAt: at,
    pathLines: const [
      RecordedPathLine(
        file: '/Users/alex/.zprofile',
        line: r'export PATH="$HOME/develop/flutter/bin:$PATH"',
      ),
    ],
  );

  test('round-trips through JSON', () {
    final record = InstallRecord.empty.withTool(flutter);
    final decoded = InstallRecord.decode(record.encode());

    final entry = decoded[ToolId.flutter]!;
    expect(entry.path, flutter.path);
    expect(entry.version, '3.47.5');
    expect(entry.installedAt, at);
    expect(entry.pathLines, flutter.pathLines);
  });

  test('owns matches the recorded path', () {
    final record = InstallRecord.empty.withTool(flutter);
    expect(record.owns(ToolId.flutter), isTrue);
    expect(
      record.owns(ToolId.flutter, path: '/Users/alex/develop/flutter/'),
      isTrue,
    );
    expect(record.owns(ToolId.flutter, path: '/Users/alex/flutter'), isFalse);
    expect(record.owns(ToolId.serverpodCli), isFalse);
  });

  test('a corrupt or foreign file reads as nothing installed', () {
    expect(InstallRecord.decode('not json').isEmpty, isTrue);
    expect(InstallRecord.decode('{"schemaVersion": 99}').isEmpty, isTrue);
  });

  test('an unknown tool is dropped without losing the rest', () {
    final decoded = InstallRecord.decode('''
{"schemaVersion": 1, "tools": {
  "opencode": {"installedAt": "2026-01-01T00:00:00Z"},
  "flutter": {"path": "/f", "installedAt": "2026-01-01T00:00:00Z"}
}}''');
    expect(decoded.tools.keys, [ToolId.flutter]);
  });

  group('on disk', () {
    late Directory tmp;

    setUp(() async {
      tmp = await Directory.systemTemp.createTemp('install_record');
    });

    tearDown(() async {
      if (await tmp.exists()) await tmp.delete(recursive: true);
    });

    test('saves into a directory that does not exist yet', () async {
      final path = p.join(tmp.path, '.serverpod', 'app_studio_installs.json');
      await InstallRecord.empty.withTool(flutter).save(path);
      expect((await InstallRecord.load(path)).owns(ToolId.flutter), isTrue);
    });

    test('an empty record deletes the file', () async {
      final path = p.join(tmp.path, 'record.json');
      await InstallRecord.empty.withTool(flutter).save(path);
      await InstallRecord.empty.save(path);
      expect(await File(path).exists(), isFalse);
    });

    test('a missing file loads as empty', () async {
      expect(
        (await InstallRecord.load(p.join(tmp.path, 'nope.json'))).isEmpty,
        isTrue,
      );
    });
  });
}
