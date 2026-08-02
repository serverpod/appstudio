import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../toolchain/tool_status.dart';
import '../toolchain/toolchain_controller.dart';
import 'dev_session_cleanup.dart';

/// IDE integration installed into new projects (agent skills + MCP config).
const _kIdeOption = 'opencode';

final _ansiEscape = RegExp(r'\x1B\[[0-9;]*[A-Za-z]');

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
  const ProjectCreator({required this.toolchains});

  final ToolchainController toolchains;

  /// Runs `serverpod create` inside [parentDirectory] and returns the path of
  /// the new project. [onStatus] receives CLI progress lines.
  Future<String> create({
    required String name,
    required String parentDirectory,
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

    final log = StringBuffer();
    final code = await _runCreate(
      name: name,
      workingDirectory: parent,
      log: log,
      onStatus: onStatus,
    );

    if (code != 0) {
      throw ProjectCreationException(
        _failureMessage(log.toString(), code),
        log: _logTail(log.toString()),
        createdPath:
            await Directory(projectPath).exists() ? projectPath : null,
      );
    }

    onStatus?.call('Configuring preview…');
    await _configureFlutterAppForPreview(projectPath: projectPath, name: name);
    return projectPath;
  }

  Future<int> _runCreate({
    required String name,
    required String workingDirectory,
    required StringBuffer log,
    void Function(String status)? onStatus,
  }) async {
    final toolchain = toolchains.current;
    final serverpod = toolchain.serverpodExecutable;
    if (serverpod == null) {
      throw ProjectCreationException(
        toolchain.unavailableReason(ToolId.serverpodCli) ??
            'The Serverpod CLI is not available.',
      );
    }

    final Process process;
    try {
      process = await Process.start(
        serverpod,
        ['create', name, '--ide', _kIdeOption, '--no-interactive'],
        workingDirectory: workingDirectory,
        environment: toolchain.processEnvironment(),
      );
    } catch (e) {
      throw ProjectCreationException(
        'Could not run the Serverpod CLI:\n$serverpod',
        log: '$e',
      );
    }

    void consume(String chunk) {
      log.write(chunk);
      final status = _lastStatusLine(chunk);
      if (status != null) onStatus?.call(status);
    }

    final stdoutSub =
        process.stdout.transform(utf8.decoder).listen(consume);
    final stderrSub =
        process.stderr.transform(utf8.decoder).listen(consume);
    final code = await process.exitCode;
    await stdoutSub.cancel();
    await stderrSub.cancel();
    return code;
  }

  /// `serverpod start` must launch the companion Flutter app as a web server
  /// on [kPreviewPort] — that is the URL the preview pane loads.
  Future<void> _configureFlutterAppForPreview({
    required String projectPath,
    required String name,
  }) async {
    final pubspec = File(p.join(projectPath, '${name}_server', 'pubspec.yaml'));
    if (!await pubspec.exists()) {
      throw ProjectCreationException(
        'Project created, but ${name}_server/pubspec.yaml was not found. '
        'The preview may not load until the Flutter app runs on port '
        '$kPreviewPort.',
        createdPath: projectPath,
      );
    }

    final patched = patchFlutterAppForPreview(await pubspec.readAsString());
    if (patched == null) {
      throw ProjectCreationException(
        'Project created, but the flutter_apps section of '
        '${name}_server/pubspec.yaml could not be updated. Set '
        '“device: web-server” and “web-port: $kPreviewPort” manually.',
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

/// Adds `device: web-server` and `web-port: <port>` to the first entry under
/// `flutter_apps:` in a Serverpod server pubspec.
///
/// Returns the updated document, or null when the block is not found.
String? patchFlutterAppForPreview(String pubspec, {int port = kPreviewPort}) {
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
  var portIndex = -1;
  for (var i = entryIndex + 1; i < lines.length; i++) {
    if (_isSkippable(lines[i])) continue;
    final indent = _indentOf(lines[i]);
    if (indent <= entryIndent) break;
    if (lastPropertyIndex == entryIndex) propertyIndent = indent;
    lastPropertyIndex = i;
    final key = lines[i].trim().split(':').first.trim();
    if (key == 'device') deviceIndex = i;
    if (key == 'web-port') portIndex = i;
  }

  final pad = ' ' * propertyIndent;
  final deviceLine = '${pad}device: web-server';
  final portLine = '${pad}web-port: $port';
  if (deviceIndex >= 0) lines[deviceIndex] = deviceLine;
  if (portIndex >= 0) lines[portIndex] = portLine;

  final additions = [
    if (deviceIndex < 0) deviceLine,
    if (portIndex < 0) portLine,
  ];
  if (additions.isNotEmpty) {
    lines.insertAll(lastPropertyIndex + 1, additions);
  }
  return lines.join('\n');
}

bool _isSkippable(String line) {
  final trimmed = line.trim();
  return trimmed.isEmpty || trimmed.startsWith('#');
}

int _indentOf(String line) => line.length - line.trimLeft().length;
