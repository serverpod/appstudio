import 'package:appstudio/platform/host_platform.dart';
import 'package:flutter_test/flutter_test.dart';

/// The rules every Windows code path leans on, pinned against both hosts so
/// the suite checks them on a Mac and on Windows alike. For macOS each answer
/// is what the code before the seam did.
void main() {
  const mac = HostPlatform.macos;
  const windows = HostPlatform.windows;

  group('home directory', () {
    test('macOS reads HOME', () {
      expect(mac.homeFrom({'HOME': '/Users/a', 'USERPROFILE': 'x'}), '/Users/a');
      expect(mac.homeFrom({'USERPROFILE': 'x'}), isNull);
    });

    test('Windows reads USERPROFILE, which is what Dart and the CLI read', () {
      expect(windows.homeFrom({'USERPROFILE': r'C:\Users\a'}), r'C:\Users\a');
      expect(windows.homeFrom({'HOME': r'C:\h'}), r'C:\h');
      expect(windows.homeFrom({'USERPROFILE': ''}), isNull);
    });
  });

  group('tool names', () {
    test('match what each SDK ships', () {
      expect(mac.flutterLauncherName, 'flutter');
      expect(mac.dartExecutableName, 'dart');
      expect(mac.installedExecutableName('serverpod'), 'serverpod');
      expect(windows.flutterLauncherName, 'flutter.bat');
      expect(windows.dartExecutableName, 'dart.exe');
      expect(windows.installedExecutableName('serverpod'), 'serverpod.bat');
    });
  });

  group('PATH', () {
    test('is split on the host separator, so C:\\ survives', () {
      expect(
        windows.splitPathList(r'C:\a;;D:\b c'),
        [r'C:\a', r'D:\b c'],
      );
      expect(mac.splitPathList('/a::/b'), ['/a', '/b']);
    });

    test('a bare command is looked for under every PATHEXT name', () {
      expect(
        windows.executableNames('flutter', pathExt: '.EXE;.BAT'),
        ['flutter.exe', 'flutter.bat'],
      );
      expect(windows.executableNames('git'), contains('git.exe'));
      expect(windows.executableNames('flutter.bat'), ['flutter.bat']);
      expect(mac.executableNames('flutter'), ['flutter']);
    });
  });

  group('paths', () {
    test('Windows compares them without regard to case', () {
      expect(windows.pathEquals(r'C:\Work\App', r'c:\work\app\'), isTrue);
      expect(mac.pathEquals('/Work/App', '/work/app'), isFalse);
      expect(mac.pathEquals('/a/b/', '/a/b'), isTrue);
    });

    test('are joined with the host separator wherever the code runs', () {
      expect(windows.path.join(r'C:\Users\a', 'develop'), r'C:\Users\a\develop');
      expect(mac.path.join('/Users/a', 'develop'), '/Users/a/develop');
    });
  });

  group('environment', () {
    test('a Windows copy finds Path under PATH and replaces it in place', () {
      final env = windows.copyEnvironment({'Path': r'C:\x', 'Other': '1'});
      expect(env['PATH'], r'C:\x');
      env['PATH'] = r'C:\y';
      expect(env.length, 2);
      expect(env.keys, contains('Path'));
      expect(env['path'], r'C:\y');
    });

    test('a macOS copy stays case-sensitive', () {
      final env = mac.copyEnvironment({'Path': 'x'});
      expect(env['PATH'], isNull);
    });

    test('Windows children keep the variables they cannot run without', () {
      final essentials = windows.essentialEnvironment({
        'SYSTEMROOT': r'C:\Windows',
        'PathExt': '.EXE',
        'Unrelated': 'no',
      });
      expect(essentials['SystemRoot'], r'C:\Windows');
      expect(essentials['PATHEXT'], '.EXE');
      expect(essentials.containsKey('Unrelated'), isFalse);
      expect(mac.essentialEnvironment({'SystemRoot': 'x'}), isEmpty);
    });
  });

  test('fromOperatingSystem maps Platform.operatingSystem', () {
    expect(HostPlatform.fromOperatingSystem('macos'), mac);
    expect(HostPlatform.fromOperatingSystem('windows'), windows);
    expect(HostPlatform.fromOperatingSystem('linux').os, HostOs.linux);
  });
}
