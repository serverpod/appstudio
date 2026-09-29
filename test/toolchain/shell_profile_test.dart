import 'dart:io';

import 'package:appstudio/toolchain/shell_profile.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

/// App Studio edits the user's shell config. Every edit has to be exactly the
/// documented line, and every removal exactly that line and nothing else.
void main() {
  group('the lines', () {
    test('Flutter\'s is the one its macOS instructions give', () {
      expect(
        flutterPathLine('/Users/alex/develop/flutter/bin', home: '/Users/alex'),
        r'export PATH="$HOME/develop/flutter/bin:$PATH"',
      );
    });

    test('dart install\'s is the one it asks for', () {
      expect(
        dartInstallPathLine(
          '/Users/alex/Library/Application Support/Dart/install/bin',
          home: '/Users/alex',
        ),
        r'export PATH="$PATH":"$HOME/Library/Application Support/Dart/install/bin"',
      );
    });

    test('a directory outside home stays absolute', () {
      expect(
        flutterPathLine('/opt/flutter/bin', home: '/Users/alex'),
        r'export PATH="/opt/flutter/bin:$PATH"',
      );
    });
  });

  group('ShellProfile', () {
    test('zsh uses .zprofile, as Flutter\'s instructions say', () {
      final profile =
          ShellProfile.resolve(home: '/h', shellOverride: '/bin/zsh');
      expect(profile.path, '/h/.zprofile');
    });

    test('bash uses .bash_profile', () {
      expect(
        ShellProfile.resolve(home: '/h', shellOverride: '/bin/bash').path,
        '/h/.bash_profile',
      );
    });

    test('anything else is shown, not guessed at', () {
      final fish =
          ShellProfile.resolve(home: '/h', shellOverride: '/opt/homebrew/bin/fish');
      expect(fish.isSupported, isFalse);
    });
  });

  group('withLine / withoutLine', () {
    const line = r'export PATH="$HOME/develop/flutter/bin:$PATH"';

    test('appends at the end', () {
      expect(withLine('# mine\n', line), '# mine\n$line\n');
      expect(withLine('# no newline', line), '# no newline\n$line\n');
      expect(withLine('', line), '$line\n');
    });

    test('does not add a line that is already there', () {
      final rc = 'a\n$line\nb\n';
      expect(withLine(rc, line), rc);
    });

    test('removes exactly that line and leaves the rest byte for byte', () {
      final rc = '# mine\n  $line\n$line\nexport FOO=1\n';
      // The indented copy is not ours — it only resembles the line.
      expect(withoutLine(rc, line), '# mine\n  $line\nexport FOO=1\n');
    });

    test('round-trips', () {
      const rc = '# mine\nexport FOO=1\n';
      expect(withoutLine(withLine(rc, line), line), rc);
    });
  });

  group('legacy block', () {
    test('is removed with the blank line before it', () {
      const rc = '# mine\n'
          '\n'
          '$kLegacyShellBlockStart\n'
          '# checksum: abc\n'
          'export PATH="/x:\$PATH"\n'
          '$kLegacyShellBlockEnd\n';
      expect(hasLegacyShellBlock(rc), isTrue);
      expect(withoutLegacyShellBlock(rc), '# mine\n');
    });

    test('leaves a file without one alone', () {
      const rc = '# mine\n';
      expect(withoutLegacyShellBlock(rc), rc);
    });
  });

  group('on disk', () {
    late Directory tmp;

    setUp(() async {
      tmp = await Directory.systemTemp.createTemp('shell_profile');
    });

    tearDown(() async {
      if (await tmp.exists()) await tmp.delete(recursive: true);
    });

    test('creates the profile when there is none', () async {
      final rc = p.join(tmp.path, '.zprofile');
      expect(await appendShellLine(rc, 'export A=1'), isTrue);
      expect(await File(rc).readAsString(), 'export A=1\n');
    });

    test('reports a line already there as not written', () async {
      // It is not App Studio's to remove later, so it must not be recorded.
      final rc = p.join(tmp.path, '.zprofile');
      await File(rc).writeAsString('export A=1\n');
      expect(await appendShellLine(rc, 'export A=1'), isFalse);
    });

    test('edits through a symlink rather than replacing it', () async {
      // Dotfile managers link these files; renaming over the link would detach
      // the user's config from their repo.
      final real = File(p.join(tmp.path, 'dotfiles', 'zprofile'));
      await real.parent.create();
      await real.writeAsString('# mine\n');
      final link = Link(p.join(tmp.path, '.zprofile'));
      await link.create(real.path);

      await appendShellLine(link.path, 'export A=1');

      expect(await FileSystemEntity.isLink(link.path), isTrue);
      expect(await real.readAsString(), '# mine\nexport A=1\n');
    });

    test('removing from a missing file is a no-op', () async {
      expect(
        await removeShellLine(p.join(tmp.path, '.nope'), 'export A=1'),
        isFalse,
      );
    });
  });
}
