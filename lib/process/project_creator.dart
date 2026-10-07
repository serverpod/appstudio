import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart' show rootBundle;
import 'package:meta/meta.dart';
import 'package:path/path.dart' as p;

import '../analytics/app_analytics.dart';
import '../runner/runner_protocol.dart' show kHeadlessWebDevice;
import '../session/project_settings.dart';
import '../toolchain/tool_status.dart';
import '../toolchain/toolchain_controller.dart';
import 'ide_integration.dart';

// `IdeIntegration` moved out to keep it clear of `dart:io`, which
// `ProjectSettings` needs it to be. Re-exported so the New Project dialog and
// its tests still reach it through the creator, where it reads naturally.
export 'ide_integration.dart';

final _ansiEscape = RegExp(r'\x1B\[[0-9;]*[A-Za-z]');

/// Agent instructions tuned for App Studio, written into every new project as
/// its `AGENTS.md`.
const kAgentsTemplateAsset = 'assets/AGENTS_template.md';

/// Serverpod project names map to Dart package names (`<name>_server`), so the
/// CLI only accepts lowercase letters, digits and underscores.
final _projectNameFormat = RegExp(r'^[a-z][a-z0-9_]*$');

/// Returns an error message when [name] is not a usable project name.
String? validateProjectName(String name) {
  if (name.isEmpty) return null;
  if (!_projectNameFormat.hasMatch(name)) {
    return name.startsWith(RegExp(r'[0-9_]'))
        ? 'Start the name with a letter.'
        : 'Use lowercase letters, numbers, and underscores only.';
  }
  return null;
}

/// Failure while running `serverpod create` or preparing the project.
class ProjectCreationException implements Exception {
  ProjectCreationException(this.message, {this.log, this.createdPath});

  final String message;

  /// Tail of the CLI output, when the failure came from `serverpod create`.
  final String? log;

  /// Set when the project exists on disk despite the failure — it can still
  /// be opened.
  final String? createdPath;

  @override
  String toString() => message;
}

/// Creates Serverpod projects with the bundled CLI and configures them for the
/// App Studio preview pane.
class ProjectCreator {
  ProjectCreator({
    required this.toolchains,
    Future<String> Function(String key)? loadAsset,
  }) : loadAsset = loadAsset ?? rootBundle.loadString;

  final ToolchainController toolchains;

  /// Reads a bundled asset. Injected (normally `rootBundle.loadString`) so a
  /// test can supply the `AGENTS.md` template without a Flutter asset bundle.
  final Future<String> Function(String key) loadAsset;

  /// Runs `serverpod create` inside [parentDirectory] and returns the path of
  /// the new project. [onStatus] receives CLI progress lines.
  ///
  /// Reports `app_studio.project_created` either way. The stage a failure
  /// came from is the one property worth having there: "the CLI failed" and
  /// "the CLI succeeded and our pubspec patch did not" are different bugs.
  Future<String> create({
    required String name,
    required String parentDirectory,
    Set<IdeIntegration> ides = const {},
    void Function(String status)? onStatus,
  }) async {
    final started = DateTime.now();
    var stage = 'validation';
    void report({required bool success}) => appAnalytics.projectCreated(
      ides: [for (final ide in ides) ide.name]..sort(),
      success: success,
      duration: DateTime.now().difference(started),
      failureStage: success ? null : stage,
    );

    try {
      final path = await _create(
        name: name,
        parentDirectory: parentDirectory,
        ides: ides,
        onStatus: onStatus,
        onStage: (next) => stage = next,
      );
      report(success: true);
      return path;
    } catch (_) {
      report(success: false);
      rethrow;
    }
  }

  Future<String> _create({
    required String name,
    required String parentDirectory,
    required Set<IdeIntegration> ides,
    required void Function(String stage) onStage,
    void Function(String status)? onStatus,
  }) async {
    final nameError = validateProjectName(name);
    if (name.isEmpty || nameError != null) {
      throw ProjectCreationException(nameError ?? 'Enter a project name.');
    }

    final parent = p.normalize(parentDirectory);
    if (!await Directory(parent).exists()) {
      throw ProjectCreationException('Location no longer exists:\n$parent');
    }

    final projectPath = p.join(parent, name);
    if (await Directory(projectPath).exists() ||
        await File(projectPath).exists()) {
      throw ProjectCreationException(
        '“$name” already exists in ${p.basename(parent)}.',
      );
    }

    onStage('cli');
    final log = StringBuffer();
    final code = await _runCreate(
      name: name,
      workingDirectory: parent,
      ides: ides,
      log: log,
      onStatus: onStatus,
    );

    if (code != 0) {
      throw ProjectCreationException(
        _failureMessage(log.toString(), code),
        log: _logTail(log.toString()),
        createdPath: await Directory(projectPath).exists() ? projectPath : null,
      );
    }

    onStage('configure_preview');
    onStatus?.call('Configuring preview…');
    await _configureFlutterAppForPreview(projectPath: projectPath, name: name);
    await recordProjectSettings(projectPath: projectPath, ides: ides);
    await applyAgentInstructions(projectPath);
    return projectPath;
  }

  /// Drops the project's root `CLAUDE.md` and writes an App Studio–tuned
  /// `AGENTS.md` over whatever the CLI left there.
  ///
  /// `serverpod create` writes a generic `AGENTS.md` (and, for the Claude IDE,
  /// a `CLAUDE.md` that points at it). App Studio's own instructions tell the
  /// agent to drive the server through App Studio rather than the command line,
  /// so the generic pair is replaced with one file.
  ///
  /// Never fails the creation: the project is complete and usable with the
  /// CLI's own instructions, and losing a finished project to an unwritable
  /// dotfile — or a missing asset — would be a far worse trade.
  @visibleForTesting
  Future<void> applyAgentInstructions(String projectPath) async {
    try {
      final claude = File(p.join(projectPath, 'CLAUDE.md'));
      if (await claude.exists()) await claude.delete();

      final template = await loadAsset(kAgentsTemplateAsset);
      await File(p.join(projectPath, 'AGENTS.md')).writeAsString(template);
    } catch (_) {
      // Ignored — see above.
    }
  }

  /// Writes `.appstudio/settings.json` so the toolbar knows which editors this
  /// project was set up for.
  ///
  /// Records [ides] as picked, *not* `configuredIdes(ides)`. The built-in
  /// entries go out as `--ide` flags whether or not they were asked for, and
  /// writing them down here would put an Open in OpenCode button on every
  /// project anyone ever created.
  ///
  /// Never fails the creation: the project is complete and usable without it,
  /// and `ProjectSettings.load` falls back to the config files the CLI just
  /// wrote. Losing a finished project to an unwritable dotfile would be a far
  /// worse trade.
  @visibleForTesting
  Future<void> recordProjectSettings({
    required String projectPath,
    required Set<IdeIntegration> ides,
  }) async {
    try {
      await ProjectSettings(editors: ides).save(projectPath);
    } on FileSystemException {
      // Ignored — see above.
    }
  }

  Future<int> _runCreate({
    required String name,
    required String workingDirectory,
    required Set<IdeIntegration> ides,
    required StringBuffer log,
    void Function(String status)? onStatus,
  }) async {
    final toolchain = toolchains.current;
    final serverpod = toolchain.serverpodExecutable;
    if (serverpod == null) {
      throw ProjectCreationException(
        toolchain.unavailableReason(ToolId.serverpodCli) ??
            'Serverpod is not installed.',
      );
    }

    final Process process;
    try {
      process = await Process.start(
        serverpod,
        [
          'create',
          name,
          for (final ide in configuredIdes(ides)) ...['--ide', ide.option],
          '--no-interactive',
        ],
        workingDirectory: workingDirectory,
        environment: toolchain.processEnvironment(),
      );
    } catch (e) {
      throw ProjectCreationException(
        'Could not run Serverpod:\n$serverpod',
        log: '$e',
      );
    }

    void consume(String chunk) {
      log.write(chunk);
      final status = _lastStatusLine(chunk);
      if (status != null) onStatus?.call(status);
    }

    final stdoutSub = process.stdout.transform(utf8.decoder).listen(consume);
    final stderrSub = process.stderr.transform(utf8.decoder).listen(consume);
    final code = await process.exitCode;
    await stdoutSub.cancel();
    await stderrSub.cancel();
    return code;
  }

  /// The runner must launch the companion Flutter app headless, as a plain
  /// web server: its default device also opens the system browser. The port is
  /// left to Flutter — the runner publishes the URL, and the preview loads
  /// whatever it says.
  Future<void> _configureFlutterAppForPreview({
    required String projectPath,
    required String name,
  }) async {
    final pubspec = File(p.join(projectPath, '${name}_server', 'pubspec.yaml'));
    if (!await pubspec.exists()) {
      throw ProjectCreationException(
        'Project created, but ${name}_server/pubspec.yaml was not found. '
        'The app may open in a browser as well as in the preview.',
        createdPath: projectPath,
      );
    }

    final patched = patchFlutterAppForPreview(await pubspec.readAsString());
    if (patched == null) {
      throw ProjectCreationException(
        'Project created, but the flutter_apps section of '
        '${name}_server/pubspec.yaml could not be updated. Set '
        '“device: $kHeadlessWebDevice” on the app manually.',
        createdPath: projectPath,
      );
    }
    await pubspec.writeAsString(patched);
  }

  String _failureMessage(String log, int exitCode) {
    final plain = log.replaceAll(_ansiEscape, '');
    for (final line in const LineSplitter().convert(plain)) {
      final trimmed = line.trim();
      if (trimmed.startsWith('ERROR:')) {
        return trimmed.substring('ERROR:'.length).trim();
      }
    }
    return 'serverpod create failed (exit code $exitCode).';
  }

  String _logTail(String log, {int lines = 12}) {
    final plain = log.replaceAll(_ansiEscape, '').replaceAll('\r', '\n');
    final all = const LineSplitter()
        .convert(plain)
        .map((l) => l.trimRight())
        .where((l) => l.isNotEmpty)
        .toList();
    if (all.length <= lines) return all.join('\n');
    return all.sublist(all.length - lines).join('\n');
  }
}

/// Last step line in [chunk] — the CLI redraws steps with `\r` and ends each
/// one with an ellipsis (`Running serverpod generator...`). Completion and
/// epilogue lines are skipped so the status keeps naming the running step.
String? _lastStatusLine(String chunk) {
  final plain = chunk.replaceAll(_ansiEscape, '').replaceAll('\r', '\n');
  for (final line in const LineSplitter().convert(plain).reversed) {
    final trimmed = line.trim();
    if (!trimmed.endsWith('...') && !trimmed.endsWith('…')) continue;
    // The CLI pads steps with a varying number of dots — normalize them.
    final label = trimmed.replaceAll(RegExp(r'[.…]+$'), '').trimRight();
    if (label.isNotEmpty) return '$label…';
  }
  return null;
}

/// Sets `device: web-server` on the first entry under `flutter_apps:` in a
/// Serverpod server pubspec.
///
/// Nothing else is touched. A `web-port` that is already there stays — the
/// runner publishes whichever port the app ends up on, so App Studio no longer
/// needs one, but a user who pinned one meant it.
///
/// Returns the updated document, or null when the block is not found.
String? patchFlutterAppForPreview(String pubspec) {
  final lines = pubspec.split('\n');

  final headerIndex = lines.indexWhere(
    (line) => RegExp(r'^\s*flutter_apps:\s*$').hasMatch(line),
  );
  if (headerIndex < 0) return null;
  final headerIndent = _indentOf(lines[headerIndex]);

  // First app alias under flutter_apps, e.g. `    my_app:`.
  var entryIndex = -1;
  for (var i = headerIndex + 1; i < lines.length; i++) {
    if (_isSkippable(lines[i])) continue;
    if (_indentOf(lines[i]) <= headerIndent) break;
    entryIndex = i;
    break;
  }
  if (entryIndex < 0) return null;
  final entryIndent = _indentOf(lines[entryIndex]);

  // Properties of that entry — track where to insert and what already exists.
  var lastPropertyIndex = entryIndex;
  var propertyIndent = entryIndent + 2;
  var deviceIndex = -1;
  for (var i = entryIndex + 1; i < lines.length; i++) {
    if (_isSkippable(lines[i])) continue;
    final indent = _indentOf(lines[i]);
    if (indent <= entryIndent) break;
    if (lastPropertyIndex == entryIndex) propertyIndent = indent;
    lastPropertyIndex = i;
    final key = lines[i].trim().split(':').first.trim();
    if (key == 'device') deviceIndex = i;
  }

  final deviceLine = '${' ' * propertyIndent}device: $kHeadlessWebDevice';
  if (deviceIndex >= 0) {
    lines[deviceIndex] = deviceLine;
  } else {
    lines.insert(lastPropertyIndex + 1, deviceLine);
  }
  return lines.join('\n');
}

bool _isSkippable(String line) {
  final trimmed = line.trim();
  return trimmed.isEmpty || trimmed.startsWith('#');
}

int _indentOf(String line) => line.length - line.trimLeft().length;
