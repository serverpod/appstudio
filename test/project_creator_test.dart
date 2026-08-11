import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:appstudio/process/project_creator.dart';
import 'package:appstudio/session/project_settings.dart';

import 'support/agent_flag.dart';
import 'support/toolchain_support.dart';

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

  group('recordProjectSettings', () {
    late Directory project;

    setUp(() {
      project = Directory.systemTemp.createTempSync('appstudio_creator_test');
    });

    tearDown(() {
      if (project.existsSync()) project.deleteSync(recursive: true);
    });

    test(
      'writes down the picks, not the editors that got configured',
      () async {
        final creator = ProjectCreator(
          toolchains: await emptyToolchainController(),
        );
        await creator.recordProjectSettings(
          projectPath: project.path,
          ides: {IdeIntegration.cursor},
        );

        // `configuredIdes` would have added OpenCode here, and every project
        // ever created would carry an Open in OpenCode button because of it.
        final settings = await ProjectSettings.load(project.path);
        expect(settings.editors, {IdeIntegration.cursor});
      },
    );

    test('an unpicked built-in editor leaves nothing behind', () async {
      final creator = ProjectCreator(
        toolchains: await emptyToolchainController(),
      );
      await creator.recordProjectSettings(
        projectPath: project.path,
        ides: const {},
      );

      final settings = await ProjectSettings.load(project.path);
      expect(settings.editors, isEmpty);
    });
  });

  group('configuredIdes', () {
    test('configures exactly what was picked, and nothing else', () {
      // OpenCode was the only `builtIn`, and it was one because App Studio ran
      // it as its own agent. With no Agent tab there is nothing to force on a
      // project the user did not ask for.
      expect(IdeIntegration.values.where((ide) => ide.builtIn), isEmpty);
      expect(configuredIdes({IdeIntegration.cursor}), {IdeIntegration.cursor});
      expect(configuredIdes({IdeIntegration.opencode}), {
        IdeIntegration.opencode,
      });
    }, skip: skipWhenAgentOn);

    test('adds the built-in editors to whatever was picked', () {
      expect(configuredIdes({IdeIntegration.cursor}), {
        IdeIntegration.opencode,
        IdeIntegration.cursor,
      });
    }, skip: skipWhenAgentOff);

    test('picking nothing still configures the built-in agent', () {
      expect(configuredIdes(const {}), {IdeIntegration.opencode});
    }, skip: skipWhenAgentOff);

    test('picking a built-in editor changes nothing', () {
      expect(configuredIdes({IdeIntegration.opencode}), {
        IdeIntegration.opencode,
      });
    }, skip: skipWhenAgentOff);
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
