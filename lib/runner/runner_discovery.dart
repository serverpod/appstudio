import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../platform/host.dart';
import 'runner_protocol.dart';

/// Finding the runner that serves a project: its server package, the manifest
/// the runner publishes there, and a socket path that fits.
///
/// Everything here mirrors `serverpod_cli`'s `runner_discovery.dart` and
/// `runner_paths.dart`, because App Studio and the CLI have to agree on where a
/// runner lives — a terminal `serverpod start` and App Studio share one runner
/// per server package, and the runner's lock is what enforces that.

/// The server package's tool directory, where the runner publishes itself.
String runnerToolDir(String serverDir) =>
    p.join(serverDir, '.dart_tool', 'serverpod');

/// The manifest a runner writes, and leaves behind when it dies.
String runnerManifestPath(String serverDir) =>
    p.join(runnerToolDir(serverDir), 'runner.json');

/// The runner's own output, written while it runs detached.
String runnerLogPath(String serverDir) =>
    p.join(runnerToolDir(serverDir), 'runner.log');

const _tuiSocketName = 'tui.sock';

/// `sockaddr_un.sun_path`, NUL included: 104 bytes on macOS, 108 on Linux and
/// Windows (whose AF_UNIX copies Linux's), as `serverpod_shared` reckons it.
int maxUnixSocketPathBytes([HostPlatform? host]) =>
    (host ?? currentHost).isMacOS ? 104 : 108;

/// What a runner publishes about itself in `runner.json`.
///
/// It outlives the runner, so a socket connection — not this file — decides
/// whether one is alive.
class RunnerManifest {
  const RunnerManifest({
    required this.pid,
    required this.projectId,
    required this.stage,
    this.exitCode,
    this.protocolVersion = kRunnerProtocolVersion,
    this.cliVersion = '',
    this.servers = const {},
  });

  /// Never proof of liveness, since pids get reused.
  final int pid;

  /// The name of the runner's link in the per-user registry.
  final String projectId;

  final RunnerStage stage;
  final int? exitCode;
  final int protocolVersion;
  final String cliVersion;

  /// The addresses the pod bound by listener name — `api`, `insights`, `web`.
  /// Empty until the pod reports them.
  final Map<String, String> servers;

  /// The runner that wrote this has finished.
  bool get isFinished => stage == RunnerStage.stopping && exitCode != null;

  static RunnerManifest fromJson(Map<String, Object?> json) => RunnerManifest(
        pid: (json['pid'] as num?)?.toInt() ?? 0,
        projectId: json['projectId'] as String? ?? '',
        stage: RunnerStage.byName(json['stage']),
        exitCode: (json['exitCode'] as num?)?.toInt(),
        protocolVersion: (json['protocolVersion'] as num?)?.toInt() ?? 0,
        cliVersion: json['cliVersion'] as String? ?? '',
        servers: switch (json['servers']) {
          final Map<Object?, Object?> map => {
              for (final MapEntry(:key, :value) in map.entries)
                if (value is String) '$key': value,
            },
          _ => const {},
        },
      );

  /// The manifest at [serverDir], or null when absent or unreadable.
  static Future<RunnerManifest?> readFrom(String serverDir) async {
    try {
      final decoded = jsonDecode(
        await File(runnerManifestPath(serverDir)).readAsString(),
      );
      if (decoded is! Map) return null;
      return fromJson(Map<String, Object?>.from(decoded));
    } on FileSystemException {
      return null;
    } on FormatException {
      return null;
    } on TypeError {
      return null;
    }
  }
}

/// The server package of the Serverpod project at [projectRoot], or null when
/// there is none.
///
/// App Studio opens a project's *root* — the folder holding `<name>_server`,
/// `<name>_client` and `<name>_flutter` — but a runner is keyed by its server
/// package, and `serverpod runner start --directory` takes exactly that. The
/// search is the downward half of the CLI's own `ServerDirectoryFinder`: the
/// folder itself, then its children two deep. More than one server package is
/// a [RunnerDiscoveryException], as it is for the CLI.
Future<String?> findServerDirectory(String projectRoot) async {
  final root = Directory(projectRoot);
  if (await isServerDirectory(root.path)) return p.normalize(root.path);

  final found = <String>[];
  Future<void> search(Directory dir, int depth) async {
    if (depth == 0) return;
    final List<FileSystemEntity> children;
    try {
      children = await dir.list(followLinks: false).toList();
    } on FileSystemException {
      return;
    }
    for (final child in children) {
      if (child is! Directory) continue;
      final name = p.basename(child.path);
      if (name.startsWith('.') || _skippedDirs.contains(name)) continue;
      if (await isServerDirectory(child.path)) {
        found.add(p.normalize(child.path));
      } else {
        await search(child, depth - 1);
      }
    }
  }

  await search(root, 2);
  if (found.length > 1) {
    found.sort();
    throw RunnerDiscoveryException(
      'This folder holds more than one Serverpod server '
      '(${found.map(p.basename).join(', ')}). Open the project folder that '
      'contains just one.',
    );
  }
  return found.singleOrNull;
}

const _skippedDirs = {'build', 'node_modules', 'Pods', 'ios', 'android'};

final _topLevelKey = RegExp(r'^([A-Za-z_][\w-]*)\s*:');
final _serverpodDependency = RegExp(r'^\s+serverpod\s*:');

/// Whether [dir] is a Serverpod server package: a pubspec that *is*
/// `serverpod` or depends on it. Read line by line — the runtime dependency
/// sits in a top-level `dependencies:` block, and that is all this needs.
Future<bool> isServerDirectory(String dir) async {
  final String pubspec;
  try {
    pubspec = await File(p.join(dir, 'pubspec.yaml')).readAsString();
  } on FileSystemException {
    return false;
  }
  String? section;
  for (final line in const LineSplitter().convert(pubspec)) {
    if (line.trimLeft().startsWith('#')) continue;
    final top = _topLevelKey.firstMatch(line);
    if (top != null) {
      section = top.group(1);
      if (section == 'name' &&
          line.substring(top.end).trim().replaceAll(RegExp('[\'"]'), '') ==
              'serverpod') {
        return true;
      }
      continue;
    }
    if (section == 'dependencies' && _serverpodDependency.hasMatch(line)) {
      return true;
    }
  }
  return false;
}

/// The per-user registry of runner links, as the CLI computes it.
String runnerRegistryDir({
  Map<String, String>? environment,
  HostPlatform? host,
}) {
  final env = environment ?? Platform.environment;
  final override = env['SERVERPOD_RUNNER_REGISTRY_DIR'];
  if (override != null && override.isNotEmpty) return override;
  final resolvedHost = host ?? currentHost;
  return resolvedHost.path
      .join(resolvedHost.homeFrom(env) ?? '', '.serverpod', 'runners');
}

/// The path by which App Studio reaches the attach socket of the runner
/// serving [serverDir].
///
/// Prefers the package path; a deep project's is longer than a Unix socket
/// address allows (104 bytes on macOS, 108 elsewhere), and then the runner's
/// registry link under `~/.serverpod/runners/<projectId>` is the way in — the
/// CLI's own clients make exactly this choice. Null when neither fits.
///
/// On Windows that link is a symbolic link, which only Developer Mode lets
/// the CLI create.
String? runnerSocketPath(
  String serverDir, {
  required String projectId,
  Map<String, String>? environment,
  HostPlatform? host,
}) {
  final resolvedHost = host ?? currentHost;
  final path = resolvedHost.path;
  final limit = maxUnixSocketPathBytes(resolvedHost);
  final candidates = [
    path.join(
      path.canonicalize(serverDir),
      '.dart_tool',
      'serverpod',
      _tuiSocketName,
    ),
    if (projectId.isNotEmpty)
      path.join(
        runnerRegistryDir(environment: environment, host: resolvedHost),
        projectId,
        _tuiSocketName,
      ),
  ];
  for (final candidate in candidates) {
    if (utf8.encode(candidate).length + 1 <= limit) {
      return candidate;
    }
  }
  return null;
}

/// Connects to the Unix socket at [path].
Future<Socket> connectRunnerSocket(
  String path, {
  Duration timeout = const Duration(seconds: 2),
}) =>
    Socket.connect(
      InternetAddress(path, type: InternetAddressType.unix),
      0,
      timeout: timeout,
    );

/// What looking for a project's runner found.
sealed class RunnerResolution {
  const RunnerResolution();
}

/// Nothing answers for the package. [staleManifest] is what a runner that
/// stopped or died left behind.
final class NoRunner extends RunnerResolution {
  const NoRunner({this.staleManifest});

  final RunnerManifest? staleManifest;
}

/// A runner answers on [socketPath].
final class LiveRunner extends RunnerResolution {
  const LiveRunner(this.manifest, {required this.socketPath});

  final RunnerManifest manifest;
  final String socketPath;
}

/// A runner answers, but speaks a protocol this build does not.
final class IncompatibleRunner extends RunnerResolution {
  const IncompatibleRunner(this.manifest);

  final RunnerManifest manifest;

  String get message =>
      'A Serverpod runner is already running for this project, but it was '
      'started by Serverpod CLI ${manifest.cliVersion}, which this version of '
      'App Studio cannot talk to. Stop it with `serverpod runner stop` and '
      'restart the server.';
}

/// Resolves the runner serving [serverDir]. A silent socket probe decides
/// liveness — no snapshot is asked for, so nothing attaches and Flutter
/// auto-launch is not armed.
Future<RunnerResolution> resolveRunner(
  String serverDir, {
  Duration probeTimeout = const Duration(seconds: 1),
  Map<String, String>? environment,
}) async {
  final manifest = await RunnerManifest.readFrom(serverDir);
  if (manifest == null) return const NoRunner();

  final path = runnerSocketPath(
    serverDir,
    projectId: manifest.projectId,
    environment: environment,
  );
  if (path == null) {
    throw RunnerDiscoveryException(
      'The runner socket for $serverDir is out of reach: no path to it fits '
      'the ${maxUnixSocketPathBytes()}-byte limit of a Unix socket address.',
    );
  }
  if (!await _isListening(path, probeTimeout)) {
    return NoRunner(staleManifest: manifest);
  }
  if (manifest.protocolVersion != kRunnerProtocolVersion) {
    return IncompatibleRunner(manifest);
  }
  return LiveRunner(manifest, socketPath: path);
}

Future<bool> _isListening(String path, Duration timeout) async {
  try {
    final probe = await connectRunnerSocket(path, timeout: timeout);
    probe.destroy();
    return true;
  } catch (_) {
    return false;
  }
}

/// A project App Studio cannot map onto exactly one runner.
class RunnerDiscoveryException implements Exception {
  const RunnerDiscoveryException(this.message);

  final String message;

  @override
  String toString() => message;
}
