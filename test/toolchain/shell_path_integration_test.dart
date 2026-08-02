import 'dart:io';

import 'package:appstudio/toolchain/shell_path_integration.dart';
import 'package:flutter_test/flutter_test.dart';

const binDir = '/Users/test/Library/Application Support/AppStudio/bin';

void main() {
  final block = renderShellBlock(binDir);

  group('renderShellBlock', () {
    test('is fenced and exports the bin dir ahead of the existing PATH', () {
      expect(block, startsWith(kShellBlockStart));
      expect(block, endsWith(kShellBlockEnd));
      expect(block, contains('export PATH="$binDir:\$PATH"'));
      expect(block, contains('# checksum: '));
    });
  });

  group('applyShellBlock', () {
    test('adds to an empty file without leading blank lines', () {
      expect(applyShellBlock('', block), '$block\n');
    });

    test('appends after existing content, separated by one blank line', () {
      final result = applyShellBlock('export FOO=1\n', block);
      expect(result, 'export FOO=1\n\n$block\n');
    });

    test('appends rather than prepends', () {
      // Prepending would land above a powerlevel10k instant-prompt guard,
      // which must stay at the very top of .zshrc.
      final rc = '# p10k instant prompt\nsource ~/.p10k.zsh\n';
      final result = applyShellBlock(rc, block);
      expect(result.indexOf('p10k'), lessThan(result.indexOf(kShellBlockStart)));
    });

    test('replaces an existing block instead of adding a second', () {
      final once = applyShellBlock('export FOO=1\n', block);
      final twice = applyShellBlock(once, block);
      expect(twice, once);
      expect(kShellBlockStart.allMatches(twice).length, 1);
    });

    test('collapses duplicate blocks left by an earlier bug', () {
      final doubled = 'export FOO=1\n\n$block\n\n$block\n';
      final result = applyShellBlock(doubled, block);
      expect(kShellBlockStart.allMatches(result).length, 1);
      expect(result, contains('export FOO=1'));
    });

    test('preserves content that follows the block', () {
      final rc = 'export A=1\n\n$block\n\nexport B=2\n';
      final result = applyShellBlock(rc, block);
      expect(result, contains('export A=1'));
      expect(result, contains('export B=2'));
      expect(kShellBlockStart.allMatches(result).length, 1);
    });
  });

  group('removeShellBlock', () {
    test('leaves a file without a block untouched', () {
      const rc = 'export FOO=1\nexport BAR=2\n';
      expect(removeShellBlock(rc), rc);
    });

    test('round-trips: adding then removing restores the original', () {
      for (final rc in [
        'export FOO=1\n',
        '# comment\n\nexport A=1\nexport B=2\n',
        '',
      ]) {
        final added = applyShellBlock(rc, block);
        expect(removeShellBlock(added), rc, reason: 'input: ${rc.length} chars');
      }
    });

    test('a file with no trailing newline gains one, and keeps it', () {
      // applyShellBlock normalises the file to end with a newline, so this one
      // case cannot round-trip byte for byte. A shell rc without a trailing
      // newline is malformed anyway, so adding one is the right outcome.
      const rc = 'no trailing newline';
      expect(removeShellBlock(applyShellBlock(rc, block)), '$rc\n');
    });

    test('an empty file stays empty, not a stray newline', () {
      expect(removeShellBlock(applyShellBlock('', block)), '');
    });

    test('removes every block when there are several', () {
      final rc = 'export A=1\n\n$block\n\n$block\n';
      final result = removeShellBlock(rc);
      expect(result, isNot(contains(kShellBlockStart)));
      expect(result, contains('export A=1'));
    });

    test('an unterminated fence is left alone rather than eating the file', () {
      // A truncated block means we cannot tell where it ends — deleting to the
      // end of the file would destroy the user's config.
      final rc = 'export A=1\n$kShellBlockStart\nexport B=2\n';
      expect(removeShellBlock(rc), rc);
    });
  });

  group('edit detection', () {
    test('an untouched block is not flagged', () {
      expect(findShellBlock(applyShellBlock('', block))!.edited, isFalse);
    });

    test('a hand-edited body is flagged', () {
      final tampered = applyShellBlock('', block)
          .replaceFirst('export PATH=', 'export PATH=/opt/mine:');
      expect(findShellBlock(tampered)!.edited, isTrue);
    });

    test('a block with no checksum at all is treated as edited', () {
      final rc = '$kShellBlockStart\nexport PATH="/x:\$PATH"\n$kShellBlockEnd\n';
      expect(findShellBlock(rc)!.edited, isTrue);
    });

    test('no block means null, not a throw', () {
      expect(findShellBlock(''), isNull);
      expect(findShellBlock('export FOO=1'), isNull);
      expect(findShellBlock(kShellBlockStart), isNull);
    });
  });

  group('ShellTarget', () {
    test('zsh targets .zshrc, which every interactive shell reads', () {
      final target = ShellTarget.resolve(
        shellOverride: '/bin/zsh',
        homeOverride: '/Users/test',
      );
      expect(target.rcPath, '/Users/test/.zshrc');
      expect(target.isSupported, isTrue);
    });

    test('bash falls back to .profile when .bash_profile is absent', () {
      final target = ShellTarget.resolve(
        shellOverride: '/bin/bash',
        homeOverride: '/Users/definitely-not-a-real-home',
      );
      expect(target.rcPath, endsWith('/.profile'));
    });

    test('fish is unsupported rather than guessed at', () {
      final target = ShellTarget.resolve(
        shellOverride: '/opt/homebrew/bin/fish',
        homeOverride: '/Users/test',
      );
      expect(target.isSupported, isFalse);
    });
  });

  group('on disk', () {
    late Directory home;
    late ShellPathIntegration integration;
    late String rcPath;

    setUp(() async {
      home = await Directory.systemTemp.createTemp('appstudio_shell');
      rcPath = '${home.path}/.zshrc';
      integration = ShellPathIntegration(
        binDir: binDir,
        target: ShellTarget.resolve(
          shellOverride: '/bin/zsh',
          homeOverride: home.path,
        ),
      );
    });

    tearDown(() => home.delete(recursive: true));

    test('enable creates the file when it does not exist', () async {
      expect(await integration.state(), ShellPathState.absent);
      await integration.enable();

      expect(File(rcPath).readAsStringSync(), contains(kShellBlockStart));
      expect(await integration.state(), ShellPathState.present);
    });

    test('disable restores the file byte for byte', () async {
      const original = '# my config\nexport EDITOR=vim\n';
      await File(rcPath).writeAsString(original);

      await integration.enable();
      expect(File(rcPath).readAsStringSync(), isNot(original));

      await integration.disable();
      expect(File(rcPath).readAsStringSync(), original);
    });

    test('enable is idempotent', () async {
      await File(rcPath).writeAsString('export FOO=1\n');
      await integration.enable();
      final once = File(rcPath).readAsStringSync();
      await integration.enable();
      expect(File(rcPath).readAsStringSync(), once);
    });

    test('refuses to overwrite a hand-edited block', () async {
      await integration.enable();
      final tampered = File(rcPath)
          .readAsStringSync()
          .replaceFirst('export PATH=', 'export PATH=/opt/mine:');
      await File(rcPath).writeAsString(tampered);

      expect(await integration.state(), ShellPathState.edited);
      await expectLater(
        integration.enable(),
        throwsA(isA<ShellPathException>()
            .having((e) => e.wasEdited, 'wasEdited', isTrue)),
      );
      // Untouched until the user explicitly chooses to replace it.
      expect(File(rcPath).readAsStringSync(), tampered);
    });

    test('force backs up before replacing an edited block', () async {
      await integration.enable();
      final tampered = File(rcPath)
          .readAsStringSync()
          .replaceFirst('export PATH=', 'export PATH=/opt/mine:');
      await File(rcPath).writeAsString(tampered);

      await integration.enable(force: true);

      final backups = home
          .listSync()
          .where((e) => e.path.contains('.appstudio-backup-'))
          .toList();
      expect(backups, hasLength(1));
      expect(File(backups.single.path).readAsStringSync(), tampered);
      expect(await integration.state(), ShellPathState.present);
    });

    test('disable backs up an edited block before removing it', () async {
      await integration.enable();
      final tampered = File(rcPath)
          .readAsStringSync()
          .replaceFirst('export PATH=', 'export PATH=/opt/mine:');
      await File(rcPath).writeAsString(tampered);

      await integration.disable();

      expect(
        home.listSync().where((e) => e.path.contains('.appstudio-backup-')),
        hasLength(1),
      );
      expect(File(rcPath).readAsStringSync(), isNot(contains(kShellBlockStart)));
    });

    test('disable on a file without a block does nothing', () async {
      await File(rcPath).writeAsString('export FOO=1\n');
      expect(await integration.disable(), isNull);
      expect(File(rcPath).readAsStringSync(), 'export FOO=1\n');
    });

    test('leaves no temp file behind', () async {
      await integration.enable();
      expect(
        home.listSync().where((e) => e.path.endsWith('.appstudio-tmp')),
        isEmpty,
      );
    });
  });
}
