import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'install_record.dart';
import 'login_shell_path.dart';
import 'shell_profile.dart';
import 'tool_status.dart';
import 'tool_version.dart';
import 'toolchain_manifest.dart';
import 'toolchain_paths.dart';

const _probeTimeout = Duration(seconds: 15);

typedef ProcessRunner = Future<ProcessResult> Function(
  String executable,
  List<String> arguments, {
  Map<String, String>? environment,
});

// ---------------------------------------------------------------------------
// Pure parsers — fed captured output, never touch the filesystem.
// ---------------------------------------------------------------------------

/// `bin/cache/flutter.version.json`, which is faster and safer than running
/// `flutter --version`: a cold SDK would start precaching artifacts.
class FlutterInfo {
  const FlutterInfo({
    required this.frameworkVersion,
    required this.channel,
    this.dartSdkVersion,
    this.frameworkRevision,
  });

  final ToolVersion? frameworkVersion;
  final String channel;
  final String? dartSdkVersion;
  final String? frameworkRevision;

  static FlutterInfo? parse(String source) {
    final Object? decoded;
    try {
      decoded = jsonDecode(source);
    } catch (_) {
      return null;
    }
    if (decoded is! Map) return null;
    return FlutterInfo(
      frameworkVersion:
          ToolVersion.tryParse(decoded['frameworkVersion'] as String?),
      channel: (decoded['channel'] as String? ?? '').trim(),
      dartSdkVersion: decoded['dartSdkVersion'] as String?,
      frameworkRevision: decoded['frameworkRevision'] as String?,
    );
  }
}

/// `Serverpod version: 4.0.0-beta.1`.
ToolVersion? parseServerpodVersion(String output) {
  final text = output.trim();
  if (text.isEmpty) return null;
  final match = _versionInText.firstMatch(text);
  return match == null ? null : ToolVersion.tryParse(match.group(1));
}

final _versionInText = RegExp(r'(\d+\.\d+(?:\.\d+)?(?:-[0-9A-Za-z.]+)?)');

// ---------------------------------------------------------------------------
// Pure qualification — everything already observed, no IO.
// ---------------------------------------------------------------------------

/// What was observed about a Flutter SDK on disk.
class FlutterObservation {
  const FlutterObservation({
    required this.hasFlutterExecutable,
    required this.hasDartExecutable,
    this.info,
  });

  final bool hasFlutterExecutable;
  final bool hasDartExecutable;
  final FlutterInfo? info;
}

/// Decides fitness for a Flutter SDK. Kept pure so every rule is unit-testable.
///
/// There is no web-artifacts check any more. It existed for the SDK App Studio
/// used to ship precached, where a missing `flutter_web_sdk` meant a broken
/// bundle; on an ordinary SDK Flutter fetches it on the first web build.
({ToolFitness fitness, String? reason}) qualifyFlutter({
  required FlutterObservation observation,
  required ToolSpec spec,
}) {
  if (!observation.hasFlutterExecutable) {
    return (fitness: ToolFitness.notFound, reason: null);
  }
  if (!observation.hasDartExecutable) {
    return (
      fitness: ToolFitness.incomplete,
      reason: 'its Dart SDK has not been downloaded yet',
    );
  }

  final info = observation.info;
  if (info == null || info.frameworkVersion == null) {
    return (
      fitness: ToolFitness.unusable,
      reason: 'could not read the Flutter version',
    );
  }

  // master and beta track a different engine than we test against.
  if (info.channel.isNotEmpty && info.channel != 'stable') {
    return (
      fitness: ToolFitness.wrongVersion,
      reason: 'on channel ${info.channel} (needs stable)',
    );
  }

  if (!spec.accepts.allows(info.frameworkVersion)) {
    return (
      fitness: ToolFitness.wrongVersion,
      reason: '${info.frameworkVersion} (needs ${spec.accepts})',
    );
  }

  return (fitness: ToolFitness.satisfied, reason: null);
}

/// Present, runs, version in range.
({ToolFitness fitness, String? reason}) qualifyVersioned({
  required bool exists,
  required ToolVersion? detected,
  required ToolSpec spec,
}) {
  if (!exists) return (fitness: ToolFitness.notFound, reason: null);
  if (detected == null) {
    return (
      fitness: ToolFitness.unusable,
      reason: 'could not read its version',
    );
  }
  if (!spec.accepts.allows(detected)) {
    return (
      fitness: ToolFitness.wrongVersion,
      reason: '$detected (needs ${spec.accepts})',
    );
  }
  return (fitness: ToolFitness.satisfied, reason: null);
}

/// What a Flutter that did not qualify takes.
///
/// A copy App Studio installed is App Studio's to fix: an old one is upgraded,
/// a broken one replaced. Anyone else's is left alone and the user is asked to
/// update it — installing a second SDK beside it would leave two `flutter`s on
/// the machine, and the one on their `PATH` would still be the old one.
ToolAction flutterAction(List<ToolCandidate> candidates, InstallRecord record) {
  if (candidates.any((c) => c.isSatisfied)) return ToolAction.none;
  for (final c in candidates) {
    if (c.fitness == ToolFitness.notFound) continue;
    if (!record.owns(ToolId.flutter, path: c.root)) return ToolAction.manual;
    return c.fitness == ToolFitness.wrongVersion
        ? ToolAction.update
        : ToolAction.install;
  }
  return ToolAction.install;
}

/// `dart install` replaces a Serverpod CLI in place and is cheap, so an old
/// one is simply reinstalled, whoever installed it.
ToolAction serverpodAction(List<ToolCandidate> candidates) {
  if (candidates.any((c) => c.isSatisfied)) return ToolAction.none;
  final found = candidates.any((c) => c.fitness != ToolFitness.notFound);
  return found ? ToolAction.update : ToolAction.install;
}

// ---------------------------------------------------------------------------
// Probing — the IO half.
// ---------------------------------------------------------------------------

class ToolProbe {
  ToolProbe({
    required this.paths,
    required this.manifest,
    required this.record,
    ProcessRunner? runner,
    LoginShellPathReader? loginShellPath,
    Map<String, String>? environment,
  })  : _run = runner ?? _defaultRunner,
        _loginShellPath = loginShellPath ?? captureLoginShellPath,
        _env = environment ?? Platform.environment;

  final ToolchainPaths paths;
  final ToolManifest manifest;
  final InstallRecord record;

  /// Where `PATH`, `FLUTTER_ROOT` and `PUB_CACHE` are read from. Injected in
  /// tests, which would otherwise find whatever the machine running them has.
  final Map<String, String> _env;

  final ProcessRunner _run;
  final LoginShellPathReader _loginShellPath;
  Future<String?>? _shellPath;

  static Future<ProcessResult> _defaultRunner(
    String executable,
    List<String> arguments, {
    Map<String, String>? environment,
  }) {
    return Process.run(
      executable,
      arguments,
      environment: environment,
      includeParentEnvironment: false,
      runInShell: false,
    ).timeout(_probeTimeout);
  }

  /// Resolves every tool.
  ///
  /// [deep] enumerates *all* candidates, which the Tools tab wants. The
  /// default stops at the first satisfied candidate per tool: probing
  /// everything costs seconds of `Process.run`, and this runs before the first
  /// frame.
  Future<ToolchainInventory> inventory({bool deep = false}) async {
    final tools = <ToolId, ToolStatus>{};

    // Flutter first: the Serverpod probe needs `dart` on PATH to run a
    // `pub global activate`d launcher.
    final flutter = await _probeFlutter(deep: deep);
    tools[ToolId.flutter] = flutter;
    final dartExecutable = flutter.resolved?.facts['dartExecutable'];

    final rest = await Future.wait([
      _probeCommandLineTools(),
      _probeServerpod(dartExecutable, deep: deep),
    ]);
    for (final status in rest) {
      tools[status.id] = status;
    }

    return ToolchainInventory(
      manifest: manifest,
      tools: tools,
      legacyInstallFound: await _legacyInstallFound(),
    );
  }

  ToolSource _sourceFor(ToolId id, String? path) =>
      record.owns(id, path: path) ? ToolSource.appStudio : ToolSource.host;

  // -- Command Line Tools ---------------------------------------------------

  /// Satisfied by the standalone tools or a full Xcode, whichever
  /// `xcode-select` points at. What Flutter and Serverpod need from either is
  /// a real `git`, `install_name_tool` and `otool` behind the `/usr/bin` shims.
  Future<ToolStatus> _probeCommandLineTools() async {
    final spec = manifest[ToolId.commandLineTools]!;
    const id = ToolId.commandLineTools;
    final dir = await _developerDir();
    if (dir == null) {
      return ToolStatus(
        spec: spec,
        candidates: const [ToolCandidate.notFound(id, ToolSource.host)],
        action: ToolAction.install,
      );
    }
    final git = p.join(dir, 'usr', 'bin', 'git');
    final hasGit = await File(git).exists();
    return ToolStatus(
      spec: spec,
      candidates: [
        ToolCandidate(
          id: id,
          source: _sourceFor(id, null),
          fitness: hasGit ? ToolFitness.satisfied : ToolFitness.incomplete,
          reason: hasGit ? null : 'git is missing from $dir',
          root: dir,
          executable: hasGit ? git : null,
        ),
      ],
      action: hasGit ? ToolAction.none : ToolAction.install,
    );
  }

  /// `xcode-select -p` is a real binary that exits non-zero without prompting
  /// when no developer directory is selected.
  Future<String?> _developerDir() async {
    try {
      final result = await _run('/usr/bin/xcode-select', const ['-p']);
      if (result.exitCode != 0) return null;
      final path = (result.stdout as String).trim();
      if (path.isEmpty || !await Directory(path).exists()) return null;
      return path;
    } catch (_) {
      return null;
    }
  }

  // -- Flutter --------------------------------------------------------------

  Future<ToolStatus> _probeFlutter({required bool deep}) async {
    final spec = manifest[ToolId.flutter]!;
    final candidates = <ToolCandidate>[];
    for (final root in await _flutterRoots()) {
      final candidate = await _flutterAt(root, spec);
      if (candidate.fitness == ToolFitness.notFound && !deep) continue;
      candidates.add(candidate);
      if (candidate.isSatisfied && !deep) break;
    }
    return ToolStatus(
      spec: spec,
      candidates: candidates,
      action: flutterAction(candidates, record),
    );
  }

  Future<ToolCandidate> _flutterAt(String root, ToolSpec spec) async {
    final flutterExe = p.join(root, 'bin', 'flutter');
    final dartExe = p.join(root, 'bin', 'cache', 'dart-sdk', 'bin', 'dart');
    final versionFile =
        File(p.join(root, 'bin', 'cache', 'flutter.version.json'));

    FlutterInfo? info;
    if (await versionFile.exists()) {
      info = FlutterInfo.parse(await versionFile.readAsString());
    }

    final observation = FlutterObservation(
      hasFlutterExecutable: await File(flutterExe).exists(),
      hasDartExecutable: await File(dartExe).exists(),
      info: info,
    );
    final verdict = qualifyFlutter(observation: observation, spec: spec);
    final source = _sourceFor(ToolId.flutter, root);
    if (verdict.fitness == ToolFitness.notFound) {
      return ToolCandidate.notFound(ToolId.flutter, source);
    }

    return ToolCandidate(
      id: ToolId.flutter,
      source: source,
      fitness: verdict.fitness,
      reason: verdict.reason,
      root: root,
      executable: flutterExe,
      detectedVersion: info?.frameworkVersion,
      facts: {
        'flutterRoot': root,
        if (observation.hasDartExecutable) 'dartExecutable': dartExe,
        if (info != null && info.channel.isNotEmpty) 'channel': info.channel,
      },
    );
  }

  /// Every place a Flutter SDK is looked for, in precedence order: what the
  /// user's own shell would run first, then the conventional locations.
  Future<List<String>> _flutterRoots() async {
    final roots = <String>[];
    void add(String? path) {
      if (path == null || path.isEmpty) return;
      final normalized = p.normalize(path);
      if (!roots.contains(normalized)) roots.add(normalized);
    }

    add(_env['FLUTTER_ROOT']);
    final onPath = await _which('flutter');
    if (onPath != null) {
      // <root>/bin/flutter → <root>
      add(p.dirname(p.dirname(await _resolveSymlink(onPath))));
    }
    add(record[ToolId.flutter]?.path);
    add(paths.flutterInstallDir);
    final home = paths.home;
    add(p.join(home, 'development', 'flutter'));
    add(p.join(home, 'flutter'));
    add(p.join(home, 'fvm', 'default'));
    return roots;
  }

  // -- Serverpod ------------------------------------------------------------

  Future<ToolStatus> _probeServerpod(
    String? dartExecutable, {
    required bool deep,
  }) async {
    final spec = manifest[ToolId.serverpodCli]!;
    final candidates = <ToolCandidate>[];

    // A `pub global activate`d launcher is a shell script that calls bare
    // `dart`.
    final env = <String, String>{
      'PATH': [
        if (dartExecutable != null) p.dirname(dartExecutable),
        '/usr/bin',
        '/bin',
      ].join(':'),
      'HOME': paths.home,
    };

    for (final path in await _serverpodPaths()) {
      final detected = parseServerpodVersion(
        await _runForOutput(path, const ['--version'], environment: env),
      );
      final verdict =
          qualifyVersioned(exists: true, detected: detected, spec: spec);
      candidates.add(
        ToolCandidate(
          id: spec.id,
          source: _sourceFor(ToolId.serverpodCli, path),
          fitness: verdict.fitness,
          reason: verdict.reason,
          root: p.dirname(p.dirname(path)),
          executable: path,
          detectedVersion: detected,
        ),
      );
      if (verdict.fitness == ToolFitness.satisfied && !deep) break;
    }

    return ToolStatus(
      spec: spec,
      candidates: candidates,
      action: serverpodAction(candidates),
    );
  }

  Future<List<String>> _serverpodPaths() async {
    final found = <String>[];
    final pubCache = _env['PUB_CACHE'] ??
        p.join(paths.home, '.pub-cache');
    for (final candidate in [
      // Where `dart install serverpod_cli` puts it — what App Studio installs,
      // and the documented way. The ~/.pub-cache/bin copy is the one that goes
      // stale.
      p.join(paths.dartInstallBinDir, 'serverpod'),
      p.join(pubCache, 'bin', 'serverpod'),
      await _which('serverpod'),
    ]) {
      if (candidate == null || found.contains(candidate)) continue;
      if (await File(candidate).exists()) found.add(candidate);
    }
    return found;
  }

  // -- Legacy ---------------------------------------------------------------

  Future<bool> _legacyInstallFound() async {
    for (final path in paths.legacyPaths) {
      if (await Directory(path).exists()) return true;
    }
    for (final rc in paths.legacyShellFiles) {
      if (await fileHasLegacyShellBlock(rc)) return true;
    }
    return false;
  }

  // -- shared helpers -------------------------------------------------------

  Future<String> _runForOutput(
    String executable,
    List<String> arguments, {
    Map<String, String>? environment,
  }) async {
    try {
      final result = await _run(executable, arguments, environment: environment);
      return '${result.stdout}\n${result.stderr}';
    } catch (_) {
      return '';
    }
  }

  /// Finds [command] on the `PATH` we inherited, and failing that on the one
  /// the user's own login shell would set up.
  ///
  /// The second lookup is what makes a Finder launch behave like a terminal
  /// launch. Opened from Finder we inherit launchd's `PATH`
  /// (`/usr/bin:/bin:/usr/sbin:/sbin`), so a Flutter SDK or a `dart install`ed
  /// Serverpod CLI outside the conventional locations resolves to nothing and
  /// the user is offered an install of tools they already have.
  ///
  /// It is deliberately a *fallback*: the shell costs ~80 ms, and on a launch
  /// that already inherited a usable `PATH` it never runs at all.
  Future<String?> _which(String command) async {
    final inherited = await whichOnPath(command, _env['PATH']);
    if (inherited != null) return inherited;
    return whichOnPath(command, await _resolveLoginShellPath());
  }

  /// Memoises the *future*, not the value it settles to: two probes reach
  /// here concurrently, and a `bool` guard set before the await would let the
  /// second read a field that is still null.
  Future<String?> _resolveLoginShellPath() =>
      _shellPath ??= _readLoginShellPath();

  Future<String?> _readLoginShellPath() async {
    try {
      return await _loginShellPath();
    } catch (_) {
      // Never fatal — a shell we cannot read just means no extra candidates.
      return null;
    }
  }

  Future<String> _resolveSymlink(String path) async {
    try {
      return await File(path).resolveSymbolicLinks();
    } catch (_) {
      return path;
    }
  }
}

/// First executable named [command] in the colon-separated [searchPath], or
/// null when there is none.
///
/// Scanned here rather than shelled out to `/usr/bin/which`: every probe
/// subprocess runs with `includeParentEnvironment: false`, and `which` with no
/// `PATH` can only ever fail.
Future<String?> whichOnPath(String command, String? searchPath) async {
  if (searchPath == null || searchPath.isEmpty) return null;
  // 0o111 — `which` skips a match it could not execute, and so do we.
  const executableBits = 0x49;
  for (final dir in searchPath.split(':')) {
    if (dir.isEmpty) continue;
    final candidate = p.join(dir, command);
    // Follows symlinks: `dart install` and Homebrew both link into their bin.
    final stat = await FileStat.stat(candidate);
    if (stat.type != FileSystemEntityType.file) continue;
    if (stat.mode & executableBits == 0) continue;
    return candidate;
  }
  return null;
}

/// Whether [dir] is one of the entries of [searchPath].
bool pathContainsDir(String? searchPath, String dir) {
  if (searchPath == null) return false;
  final wanted = p.normalize(dir);
  return searchPath
      .split(':')
      .any((entry) => entry.isNotEmpty && p.normalize(entry) == wanted);
}
