import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../process/ide_integration.dart';

/// Directory App Studio keeps its per-project state in, relative to the
/// project root.
const kProjectSettingsDirName = '.appstudio';

/// Per-project state, stored beside the project in
/// `<project>/.appstudio/settings.json`.
///
/// This is not preferences — those are global and live in `SharedPreferences`.
/// It records choices that belong to the *project*, so a copy of it carries
/// them and a second machine reads the same answer.
class ProjectSettings {
  const ProjectSettings({this.editors = const {}});

  /// Editors the user **picked** in the New Project dialog.
  ///
  /// Not the set that was configured: `configuredIdes` adds the `builtIn` ones
  /// whether they were asked for or not, and recording those here would put an
  /// Open in OpenCode button on every project ever created. What belongs in
  /// this file is the choice, not its consequences.
  final Set<IdeIntegration> editors;

  /// Bumped only if the shape changes incompatibly. An unknown version is
  /// read as far as it parses rather than discarded — losing the user's editor
  /// choices to a downgrade would be worse than ignoring a field.
  static const _version = 1;

  static File fileIn(String projectPath) =>
      File(p.join(projectPath, kProjectSettingsDirName, 'settings.json'));

  /// Reads the settings for [projectPath].
  ///
  /// Falls back to [_inferFromIdeConfig] when the file is missing or corrupt,
  /// so projects created before App Studio wrote this file still get their
  /// editors. A file that parses wins even when it lists nothing: ticking no
  /// editor is a real choice, and inferring over it would resurrect one.
  static Future<ProjectSettings> load(String projectPath) async {
    final file = fileIn(projectPath);
    try {
      if (await file.exists()) {
        final json = jsonDecode(await file.readAsString());
        if (json is Map<String, dynamic>) return ProjectSettings.fromJson(json);
      }
    } on FileSystemException {
      // Fall through to inference.
    } on FormatException {
      // Fall through to inference.
    }
    return ProjectSettings(editors: await _inferFromIdeConfig(projectPath));
  }

  Future<void> save(String projectPath) async {
    final file = fileIn(projectPath);
    await file.parent.create(recursive: true);
    await file.writeAsString(
      '${const JsonEncoder.withIndent('  ').convert(toJson())}\n',
    );
  }

  factory ProjectSettings.fromJson(Map<String, dynamic> json) {
    final editors = <IdeIntegration>{};
    final listed = json['editors'];
    if (listed is List) {
      for (final entry in listed) {
        final ide = ideIntegrationForOption(entry);
        // An unknown id is an editor a newer App Studio knows about. Dropping
        // it is right — we cannot draw a button for it — but it must not stop
        // the rest of the list being read.
        if (ide != null) editors.add(ide);
      }
    }
    return ProjectSettings(editors: editors);
  }

  Map<String, dynamic> toJson() => {
    'version': _version,
    'editors': [
      for (final ide in IdeIntegration.values)
        if (editors.contains(ide)) ide.option,
    ],
  };
}

/// Config file `serverpod create --ide <option>` writes, relative to the
/// project root — a mirror of the CLI's own `TemplateIde.filePath`.
///
/// Only used to read editors out of a project that predates
/// `.appstudio/settings.json`. Each path is specific enough that its presence
/// really does mean the CLI configured that editor: a bare `.vscode/` would
/// match half the projects on the Mac, `.vscode/mcp.json` would not.
const _ideConfigFiles = <IdeIntegration, String>{
  IdeIntegration.opencode: 'opencode.json',
  IdeIntegration.antigravity: '.agents/plugins/serverpod-local/mcp_config.json',
  IdeIntegration.claude: '.mcp.json',
  IdeIntegration.codex: '.codex/config.toml',
  IdeIntegration.cursor: '.cursor/mcp.json',
  IdeIntegration.vscode: '.vscode/mcp.json',
};

Future<Set<IdeIntegration>> _inferFromIdeConfig(String projectPath) async {
  final found = <IdeIntegration>{};
  for (final entry in _ideConfigFiles.entries) {
    // A built-in integration is configured whether or not it was picked, so its
    // config file says nothing about what the user chose — `opencode.json` is
    // in *every* project App Studio has ever created. Inferring from it would
    // reinstate the button this whole distinction exists to keep off.
    if (entry.key.builtIn) continue;
    if (await File(p.join(projectPath, entry.value)).exists()) {
      found.add(entry.key);
    }
  }
  return found;
}
