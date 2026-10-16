// Runs fake POSIX shells; Windows has no login shell to capture.
@TestOn('mac-os || linux')
@Tags(['process'])
library;

import 'dart:io';

import 'package:appstudio/toolchain/login_shell_path.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  /// A stand-in login shell. Real shells are unusable in a test — the answer
  /// would depend on whoever's machine is running it — so this one takes the
  /// `-c` script the production code generates and runs it for real against a
  /// PATH we control. That keeps the generated script, the markers and the
  /// noise handling all under test.
  Future<String> fakeShell(String body) async {
    final dir = await Directory.systemTemp.createTemp('appstudio_shell');
    addTearDown(() => dir.delete(recursive: true));
    final shell = File(p.join(dir.path, 'zsh'));
    await shell.writeAsString(body);
    await Process.run('/bin/chmod', ['755', shell.path]);
    return shell.path;
  }

  group('captureLoginShellPath', () {
    test('returns the PATH the shell sets up, ignoring rc noise', () async {
      // Args arrive as -l -i -c <script>, so the script is $4. The banner and
      // the warning are what a real .zshrc emits around the answer.
      final shell = await fakeShell('#!/bin/sh\n'
          'echo "Welcome to your shell"\n'
          'echo "compinit: insecure directories" >&2\n'
          'PATH="/opt/tools/bin:\$PATH"\n'
          'exec /bin/sh -c "\$4"\n');

      final path = await captureLoginShellPath(shellOverride: shell);
      expect(path, isNotNull);
      expect(path!.split(':'), contains('/opt/tools/bin'));
      expect(path, isNot(contains('Welcome')));
    });

    test('kills a shell that hangs instead of waiting on it', () async {
      // An rc that blocks — waiting on stdin, or a slow version manager — must
      // not hold up the probe. Future.timeout would return and leave the shell
      // running, so this checks the process is actually gone.
      final shell = await fakeShell('#!/bin/sh\nsleep 30\n');

      final stopwatch = Stopwatch()..start();
      final path = await captureLoginShellPath(
        shellOverride: shell,
        timeout: const Duration(milliseconds: 300),
      );
      stopwatch.stop();

      expect(path, isNull);
      expect(stopwatch.elapsed, lessThan(const Duration(seconds: 5)));

      final leftovers = await Process.run('/bin/ps', ['-o', 'command=', '-A']);
      expect('${leftovers.stdout}', isNot(contains(shell)));
    });

    test('returns null rather than throwing when there is no such shell',
        () async {
      expect(
        await captureLoginShellPath(shellOverride: '/nonexistent/shell'),
        isNull,
      );
    });

    test('returns null when the shell prints nothing usable', () async {
      final shell = await fakeShell('#!/bin/sh\necho "just noise"\n');
      expect(await captureLoginShellPath(shellOverride: shell), isNull);
    });
  });

  group('shellPathScript', () {
    test('braces the variable', () {
      // Unbraced, `$PATH__APP_STUDIO_PATH__` is a different variable name to
      // the shell: it expands to nothing, and the empty result reads as a
      // clean "no PATH found" rather than as the quoting bug it is.
      expect(shellPathScript('/bin/zsh'), contains(r'${PATH}'));
    });

    test('uses fish syntax for fish, which lists its PATH and has no brace form',
        () {
      expect(shellPathScript('/opt/homebrew/bin/fish'), contains('string join'));
    });
  });

  group('extractMarkedPath', () {
    test('takes only what is between the markers', () {
      const marker = '__APP_STUDIO_PATH__';
      expect(
        extractMarkedPath('banner\n$marker/a/bin:/b/bin$marker'),
        '/a/bin:/b/bin',
      );
    });

    test('returns null on a half-written pair, which is what a kill leaves',
        () {
      expect(extractMarkedPath('__APP_STUDIO_PATH__/a/bin'), isNull);
      expect(extractMarkedPath('nothing at all'), isNull);
      expect(extractMarkedPath('__APP_STUDIO_PATH____APP_STUDIO_PATH__'), isNull);
    });
  });
}
