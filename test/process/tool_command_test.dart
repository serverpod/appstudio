import 'dart:io';

import 'package:appstudio/platform/host_platform.dart';
import 'package:appstudio/process/tool_command.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

/// What actually gets started for a tool. Phase 0 measured why this matters on
/// Windows: handed straight to a batch file, the argument `a&b` ran `b` as a
/// command of its own, and a path with a space broke `runInShell`.
void main() {
  late Directory tmp;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('tool_command_');
  });

  tearDown(() => tmp.delete(recursive: true));

  Future<String> write(String name, String contents) async {
    final file = File(p.join(tmp.path, name));
    await file.create(recursive: true);
    await file.writeAsString(contents);
    return file.path;
  }

  test('macOS starts every tool as given', () {
    final command = resolveToolCommand(
      '/Users/a/develop/flutter/bin/flutter',
      ['pub', 'get', 'a&b'],
      host: HostPlatform.macos,
    );
    expect(command.executable, '/Users/a/develop/flutter/bin/flutter');
    expect(command.arguments, ['pub', 'get', 'a&b']);
  });

  group('on Windows', () {
    const windows = HostPlatform.windows;

    test('an .exe is started as given, whatever its arguments', () {
      final command = resolveToolCommand(
        r'C:\sdk\dart.exe',
        [r'C:\Users\Åsa Öberg\my project', 'a&b'],
        host: windows,
      );
      expect(command.executable, r'C:\sdk\dart.exe');
      expect(command.arguments, [r'C:\Users\Åsa Öberg\my project', 'a&b']);
    });

    test('a dart install launcher is skipped for the .exe it names', () async {
      final exe = await write(
        p.join('app-bundles', 'serverpod_cli', 'bundle', 'bin', 'serverpod.exe'),
        '',
      );
      final launcher = await write(
        'serverpod.bat',
        '@ECHO OFF\r\nREM target_file_path_marker\r\n"$exe" %*\r\n'
            'EXIT /B %ERRORLEVEL%\r\n',
      );

      final command = resolveToolCommand(
        launcher,
        ['runner', 'start', '--directory', r'C:\Users\Åsa Öberg\a&b_server'],
        host: windows,
      );

      expect(command.executable, exe);
      expect(command.arguments.last, r'C:\Users\Åsa Öberg\a&b_server');
    });

    test('a launcher whose .exe is gone is treated as any batch file',
        () async {
      final launcher = await write(
        'serverpod.bat',
        '@ECHO OFF\r\nREM target_file_path_marker\r\n'
            '"C:\\nowhere\\serverpod.exe" %*\r\n',
      );
      expect(
        resolveToolCommand(launcher, ['--version'], host: windows).executable,
        launcher,
      );
    });

    test('another batch file takes plain words and flags', () async {
      final flutter = await write('flutter.bat', '@ECHO off\r\n');
      final command = resolveToolCommand(
        flutter,
        ['pub', 'get', '--web', 'channel', 'stable'],
        host: windows,
      );
      expect(command.executable, flutter);
    });

    for (final argument in [
      'a&b',
      'two words',
      '100%PATH%',
      'x^y',
      'quote"inside',
      'pipe|x',
      '(paren)',
      '',
    ]) {
      test('another batch file refuses ${argument.isEmpty ? 'an empty argument' : argument}',
          () async {
        final flutter = await write('flutter.bat', '@ECHO off\r\n');
        expect(
          () => resolveToolCommand(flutter, ['pub', argument], host: windows),
          throwsA(isA<UnsafeBatchArgumentException>()),
        );
      });
    }
  });
}
