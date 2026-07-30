import 'package:flutter_test/flutter_test.dart';

import 'package:appstudio/process/project_creator.dart';

/// Tail of a pubspec written by `serverpod create` (4.0.0-beta.1).
const _serverPubspec = '''
name: testapp_server

serverpod:
  scripts:
    flutter_build:
      posix: |
        cd ../testapp_flutter
        flutter build web --base-href / --output ../testapp_server/web/app

  # Companion Flutter apps that `serverpod start` can launch (Ctrl+R), keyed
  # by a display alias.
  #
  # Admin:
  #   path: ../apps/admin_flutter
  #   device: chrome
  #   web-port: 8090
  flutter_apps:
    testapp:
      path: ../testapp_flutter
      displayName: "Testapp"
      auto_launch: true
      target: lib/driver.dart
''';

void main() {
  group('validateProjectName', () {
    test('accepts lowercase names with digits and underscores', () {
      expect(validateProjectName('my_app2'), isNull);
      expect(validateProjectName('a'), isNull);
    });

    test('rejects names that do not start with a letter', () {
      expect(validateProjectName('1app'), contains('letter'));
      expect(validateProjectName('_app'), contains('letter'));
    });

    test('rejects uppercase and special characters', () {
      expect(validateProjectName('MyApp'), isNotNull);
      expect(validateProjectName('my-app'), isNotNull);
    });

    test('says nothing about an empty name', () {
      expect(validateProjectName(''), isNull);
    });
  });

  group('patchFlutterAppForPreview', () {
    test('appends device and web-port to the app entry', () {
      final patched = patchFlutterAppForPreview(_serverPubspec)!;
      expect(
        patched,
        endsWith(
          '      target: lib/driver.dart\n'
          '      device: web-server\n'
          '      web-port: 9998\n',
        ),
      );
      // Commented example values are left alone.
      expect(patched, contains('#   web-port: 8090'));
    });

    test('replaces values that are already set', () {
      final once = patchFlutterAppForPreview(_serverPubspec)!;
      final twice = patchFlutterAppForPreview(
        once.replaceFirst('device: web-server', 'device: chrome'),
      )!;
      expect(twice, once);
    });

    test('returns null when there is no flutter_apps block', () {
      expect(patchFlutterAppForPreview('name: testapp_server\n'), isNull);
    });
  });
}
