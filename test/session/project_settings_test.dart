import 'dart:convert';
import 'dart:io';

import 'package:appstudio/process/ide_integration.dart';
import 'package:appstudio/session/project_settings.dart';
import 'package:path/path.dart' as p;
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory project;

  setUp(() {
    project = Directory.systemTemp.createTempSync('appstudio_settings_test');
  });

  tearDown(() {
    if (project.existsSync()) project.deleteSync(recursive: true);
  });

  void writeProjectFile(String relative, String contents) {
    final file = File(p.join(project.path, relative));
    file.parent.createSync(recursive: true);
    file.writeAsStringSync(contents);
  }

  test('round-trips the editors it was saved with', () async {
    await const ProjectSettings(
      editors: {IdeIntegration.cursor, IdeIntegration.opencode},
    ).save(project.path);

    final settings = await ProjectSettings.load(project.path);
    expect(settings.editors, {IdeIntegration.opencode, IdeIntegration.cursor});
  });

  test('writes the ids `serverpod create --ide` uses', () async {
    await const ProjectSettings(
      editors: {IdeIntegration.vscode},
    ).save(project.path);

    final json =
        jsonDecode(ProjectSettings.fileIn(project.path).readAsStringSync())
            as Map<String, dynamic>;
    expect(json['editors'], ['vscode']);
  });

  test('drops an id it does not know without losing the rest', () async {
    writeProjectFile(
      p.join(kProjectSettingsDirName, 'settings.json'),
      '{"version": 1, "editors": ["cursor", "some_future_editor", 7]}',
    );

    final settings = await ProjectSettings.load(project.path);
    expect(settings.editors, {IdeIntegration.cursor});
  });

  group('with no settings file', () {
    test('infers the editors from the config the CLI wrote', () async {
      writeProjectFile('.cursor/mcp.json', '{}');
      writeProjectFile('.vscode/mcp.json', '{}');

      final settings = await ProjectSettings.load(project.path);
      expect(settings.editors, {IdeIntegration.cursor, IdeIntegration.vscode});
    });

    test('never infers a built-in integration', () async {
      // `--ide opencode` runs whether or not the box was ticked, so every
      // project has an `opencode.json` and it says nothing about the choice.
      writeProjectFile('opencode.json', '{}');
      writeProjectFile('.cursor/mcp.json', '{}');

      final settings = await ProjectSettings.load(project.path);
      expect(settings.editors, {IdeIntegration.cursor});
    });

    test(
      'does not infer from a directory the CLI did not write into',
      () async {
        // Half the projects on a Mac have a `.vscode/`; only `.vscode/mcp.json`
        // means `--ide vscode` ran.
        writeProjectFile('.vscode/launch.json', '{}');

        final settings = await ProjectSettings.load(project.path);
        expect(settings.editors, isEmpty);
      },
    );

    test('infers nothing from an empty project', () async {
      final settings = await ProjectSettings.load(project.path);
      expect(settings.editors, isEmpty);
    });
  });

  test('a file listing no editors wins over inference', () async {
    // Ticking nothing is a real choice, and the config the CLI left behind
    // must not be read as one.
    writeProjectFile('.cursor/mcp.json', '{}');
    await const ProjectSettings().save(project.path);

    final settings = await ProjectSettings.load(project.path);
    expect(settings.editors, isEmpty);
  });

  test('records OpenCode only when it was actually picked', () async {
    await const ProjectSettings(
      editors: {IdeIntegration.opencode, IdeIntegration.cursor},
    ).save(project.path);

    final settings = await ProjectSettings.load(project.path);
    expect(settings.editors, {IdeIntegration.opencode, IdeIntegration.cursor});
  });

  test('falls back to inference when the file will not parse', () async {
    writeProjectFile('.cursor/mcp.json', '{}');
    writeProjectFile(
      p.join(kProjectSettingsDirName, 'settings.json'),
      'not json at all',
    );

    final settings = await ProjectSettings.load(project.path);
    expect(settings.editors, {IdeIntegration.cursor});
  });
}
