import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../runner/runner_log.dart';
import '../toolchain/tool_status.dart';
import '../toolchain/toolchain.dart';
import 'tool_command.dart';

final _flutterSdkDep = RegExp(r'sdk:\s*flutter');

/// Runs `pub get` for every package of the project at [projectPath], writing
/// what it does to [log], before a runner is started for it.
///
/// With the toolchain's own Dart and Flutter, so a project carried over from
/// another machine — with a stale `.dart_tool` — resolves against this Mac.
/// Only ever before App Studio *starts* a runner: one already running owns the
/// project's packages, and a `pub get` underneath it is the last thing it
/// needs.
///
/// [isCancelled] is checked between packages, so a project switch mid-way
/// stops the rest.
Future<void> resolveProjectDependencies(
  String projectPath, {
  required Toolchain toolchain,
  required RunnerLog log,
  bool Function()? isCancelled,
}) async {
  final env = toolchain.processEnvironment();

  final workspaceRoot = await _findWorkspaceRoot(projectPath);
  final packages = workspaceRoot != null
      ? <String>[workspaceRoot]
      : await _discoverPackages(projectPath);
  if (packages.isEmpty) {
    log.addLocal('No pubspec.yaml packages found under the project.');
    return;
  }

  if (workspaceRoot != null) {
    log.addLocal('Dart workspace: ${p.basename(workspaceRoot)}');
  }

  for (final pkg in packages) {
    if (isCancelled?.call() ?? false) return;
    final useFlutter = workspaceRoot != null
        ? await _workspaceHasFlutterPackage(workspaceRoot)
        : await _isFlutterPackage(pkg);
    final exe =
        useFlutter ? toolchain.flutterExecutable : toolchain.dartExecutable;
    if (exe == null) {
      throw Exception(toolchain.unavailableReason(ToolId.flutter));
    }
    final label = p.basename(pkg);
    log.addLocal('${useFlutter ? 'flutter' : 'dart'} pub get ($label)');
    final command = resolveToolCommand(exe, const ['pub', 'get']);
    final process = await Process.start(
      command.executable,
      command.arguments,
      workingDirectory: pkg,
      environment: env,
    );
    final output = <Future<void>>[
      for (final stream in [process.stdout, process.stderr])
        stream
            .transform(utf8.decoder)
            .transform(const LineSplitter())
            .where((line) => line.trim().isNotEmpty)
            .forEach(log.addLocal),
    ];
    final code = await process.exitCode;
    await Future.wait(output);
    if (code != 0) {
      throw Exception(
        'pub get failed in $label (exit $code). See the server log — the '
        'first run needs a network connection.',
      );
    }
  }

  await _assertServerpodPackageResolved(workspaceRoot ?? projectPath, log);
}

/// Walk up from [start] looking for a pubspec with a `workspace:` key.
Future<String?> _findWorkspaceRoot(String start) async {
  var dir = p.normalize(start);
  while (true) {
    final pubspec = File(p.join(dir, 'pubspec.yaml'));
    if (await pubspec.exists()) {
      try {
        final text = await pubspec.readAsString();
        if (RegExp(r'^workspace\s*:', multiLine: true).hasMatch(text)) {
          return dir;
        }
      } catch (_) {}
    }
    final parent = p.dirname(dir);
    if (parent == dir) return null;
    dir = parent;
  }
}

Future<bool> _workspaceHasFlutterPackage(String workspaceRoot) async {
  for (final pkg in await _discoverPackages(workspaceRoot)) {
    if (await _isFlutterPackage(pkg)) return true;
  }
  return false;
}

Future<List<String>> _discoverPackages(String root) async {
  final found = <String>[];
  Future<void> consider(String dir) async {
    if (await File(p.join(dir, 'pubspec.yaml')).exists()) found.add(dir);
  }

  await consider(root);
  final rootDir = Directory(root);
  if (!await rootDir.exists()) return found;

  await for (final entity in rootDir.list(followLinks: false)) {
    if (entity is! Directory) continue;
    if (p.basename(entity.path).startsWith('.')) continue;
    await consider(entity.path);
  }
  return found;
}

Future<bool> _isFlutterPackage(String dir) async {
  try {
    final text = await File(p.join(dir, 'pubspec.yaml')).readAsString();
    return _flutterSdkDep.hasMatch(text);
  } catch (_) {
    return false;
  }
}

/// Ensure `package:serverpod` resolves to a directory that exists on disk.
Future<void> _assertServerpodPackageResolved(
  String resolutionRoot,
  RunnerLog log,
) async {
  final configFile = File(
    p.join(resolutionRoot, '.dart_tool', 'package_config.json'),
  );
  if (!await configFile.exists()) {
    throw Exception(
      'Missing .dart_tool/package_config.json under $resolutionRoot after '
      'pub get. Try opening the workspace root folder.',
    );
  }

  late final Map<String, dynamic> config;
  try {
    config =
        jsonDecode(await configFile.readAsString()) as Map<String, dynamic>;
  } catch (e) {
    throw Exception('Invalid package_config.json: $e');
  }

  final packages = config['packages'];
  if (packages is! List) {
    throw Exception('package_config.json has no packages list');
  }

  Map<String, dynamic>? serverpod;
  for (final entry in packages) {
    if (entry is Map<String, dynamic> && entry['name'] == 'serverpod') {
      serverpod = entry;
      break;
    }
  }
  if (serverpod == null) {
    throw Exception(
      'package:serverpod is not in package_config.json. '
      'Check that the server pubspec depends on serverpod and pub get '
      'succeeded (network required on first run).',
    );
  }

  final rootUri = serverpod['rootUri'] as String?;
  if (rootUri == null || rootUri.isEmpty) {
    throw Exception('package:serverpod has an empty rootUri');
  }

  final uri = Uri.parse(rootUri);
  final rootPath = uri.scheme == 'file'
      ? uri.toFilePath()
      : p.normalize(p.join(resolutionRoot, '.dart_tool', rootUri));
  if (!await Directory(rootPath).exists()) {
    throw Exception(
      'package:serverpod points to a missing directory:\n  $rootPath\n'
      'Delete the project .dart_tool folders and try again.',
    );
  }

  if (!await File(p.join(rootPath, 'lib', 'serverpod.dart')).exists()) {
    throw Exception(
      'package:serverpod is incomplete (missing lib/serverpod.dart) at:\n'
      '  $rootPath',
    );
  }

  log.addLocal('Resolved package:serverpod → $rootPath');
}
