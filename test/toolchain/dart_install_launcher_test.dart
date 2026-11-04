import 'dart:io';

import 'package:appstudio/toolchain/toolchain_installer.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  late Directory tmp;
  late String launcher;
  late File target;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('dart_install_launcher');
    launcher = p.join(tmp.path, 'bin', 'serverpod.bat');
    target = File(p.join(tmp.path, 'app-bundles', 'serverpod_cli', 'hosted',
        '4.1.0-beta.3', 'bundle', 'bin', 'serverpod.exe'));
    await target.parent.create(recursive: true);
    await target.writeAsString('');
    await File(launcher).parent.create(recursive: true);
    await File(launcher).writeAsString(
      '@ECHO OFF\n'
      'REM target_file_path_marker\n'
      '"${target.path}" %*\n'
      'EXIT /B %ERRORLEVEL%\n',
    );
  });

  tearDown(() async {
    if (await tmp.exists()) await tmp.delete(recursive: true);
  });

  test('a launcher the update deleted comes back', () async {
    final saved = (await readLauncher(launcher))!;
    final contents = await File(launcher).readAsString();
    await File(launcher).delete();

    expect(await restoreLauncher(saved), isTrue);
    expect(await File(launcher).readAsString(), contents);
  });

  test('one the update left is not touched', () async {
    final saved = (await readLauncher(launcher))!;
    await File(launcher).writeAsString('the new version');

    expect(await restoreLauncher(saved), isFalse);
    expect(await File(launcher).readAsString(), 'the new version');
  });

  test('nor brought back when what it ran has gone too', () async {
    final saved = (await readLauncher(launcher))!;
    await File(launcher).delete();
    await target.delete();

    expect(await restoreLauncher(saved), isFalse);
    expect(await File(launcher).exists(), isFalse);
  });

  test('a launcher whose executable is gone is not saved', () async {
    await target.delete();

    expect(await readLauncher(launcher), isNull);
    expect(await readLauncher(p.join(tmp.path, 'missing.bat')), isNull);
  });
}
