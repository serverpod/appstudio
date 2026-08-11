import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../feature_flags.dart';
import 'login_shell_path.dart';
import 'tool_status.dart';
import 'tool_version.dart';
import 'toolchain_manifest.dart';
import 'toolchain_paths.dart';
import 'toolchain_requirements.dart';

/// Paths macOS ships as Xcode Command Line Tools *shims*. Executing one on a
/// Mac without developer tools pops a modal installer — exactly the dialog this
/// whole feature exists to avoid. They are all the same ~119 KB stub binary.
const kCltShimDir = '/usr/bin';

const _probeTimeout = Duration(seconds: 15);

/// Mach-O magic numbers, little-endian as they appear on disk.
const _machOMagics = <int>[
  0xFEEDFACF, // 64-bit
  0xFEEDFACE, // 32-bit
  0xCAFEBABE, // universal (fat)
  0xBEBAFECA, // universal, byte-swapped
];

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

/// `git version 2.53.0` (Apple's adds a suffix: `2.39.5 (Apple Git-154)`).
ToolVersion? parseGitVersion(String output) =>
    _firstVersion(output, prefix: 'git version');

/// `Serverpod version: 4.0.0-beta.1`.
ToolVersion? parseServerpodVersion(String output) => _firstVersion(output);

/// OpenCode prints a bare `1.18.4`.
ToolVersion? parseOpencodeVersion(String output) => _firstVersion(output);

/// `otool --version` prints an LLVM banner; any release number will do since
/// the qualification is "is it a real tool", not "is it new enough".
ToolVersion? parseOtoolVersion(String output) => _firstVersion(output);

final _versionInText = RegExp(r'(\d+\.\d+(?:\.\d+)?(?:-[0-9A-Za-z.]+)?)');

ToolVersion? _firstVersion(String output, {String? prefix}) {
  var text = output.trim();
  if (text.isEmpty) return null;
  if (prefix != null) {
    final at = text.indexOf(prefix);
    if (at >= 0) text = text.substring(at + prefix.length);
  }
  final match = _versionInText.firstMatch(text);
  return match == null ? null : ToolVersion.tryParse(match.group(1));
}

// ---------------------------------------------------------------------------
// Pure qualification — everything already observed, no IO.
// ---------------------------------------------------------------------------

/// What was observed about a Flutter SDK on disk.
class FlutterObservation {
  const FlutterObservation({
    required this.hasFlutterExecutable,
    required this.hasDartExecutable,
    required this.hasWebSdk,
    this.info,
  });

  final bool hasFlutterExecutable;
  final bool hasDartExecutable;

  /// `bin/cache/flutter_web_sdk` only exists after `flutter precache --web`.
  final bool hasWebSdk;
  final FlutterInfo? info;
}

/// Decides fitness for a Flutter SDK. Kept pure so every rule — wrong channel,
/// un-precached web artifacts, version drift — is unit-testable.
({ToolFitness fitness, String? reason}) qualifyFlutter({
  required FlutterObservation observation,
  required ToolSpec spec,
  required ToolchainRequirements requirements,
  required bool isHost,
}) {
  if (!observation.hasFlutterExecutable) {
    return (fitness: ToolFitness.notFound, reason: null);
  }
  if (!observation.hasDartExecutable) {
    return (
      fitness: ToolFitness.incomplete,
      reason: 'the bundled Dart SDK is missing',
    );
  }

  final info = observation.info;
  if (info == null || info.frameworkVersion == null) {
    return (
      fitness: ToolFitness.unusable,
      reason: 'could not read the Flutter version',
    );
  }

  // A host SDK on master/beta tracks a different engine than we test against.
  if (isHost && info.channel.isNotEmpty && info.channel != 'stable') {
    return (
      fitness: ToolFitness.wrongVersion,
      reason: 'on channel ${info.channel} (needs stable)',
    );
  }

  if (!requirements.accepts(spec, info.frameworkVersion)) {
    return (
      fitness: ToolFitness.wrongVersion,
      reason: '${info.frameworkVersion} (needs ${requirements.describe(spec)})',
    );
  }

  // Without the web SDK the preview pane cannot build anything.
  if (!observation.hasWebSdk) {
    return (
      fitness: ToolFitness.incomplete,
      reason: 'web artifacts not precached — run flutter precache --web',
    );
  }

  return (fitness: ToolFitness.satisfied, reason: null);
}

/// Shared rule for the simple tools: present, runs, version in range.
({ToolFitness fitness, String? reason}) qualifyVersioned({
  required bool exists,
  required bool isStub,
  required ToolVersion? detected,
  required ToolSpec spec,
  required ToolchainRequirements requirements,
  String? incompleteReason,
}) {
  if (!exists) return (fitness: ToolFitness.notFound, reason: null);
  if (isStub) {
    return (
      fitness: ToolFitness.stub,
      reason: 'Xcode Command Line Tools stub',
    );
  }
  if (incompleteReason != null) {
    return (fitness: ToolFitness.incomplete, reason: incompleteReason);
  }
  if (detected == null) {
    return (
      fitness: ToolFitness.unusable,
      reason: 'could not read its version',
    );
  }
  if (!requirements.accepts(spec, detected)) {
    return (
      fitness: ToolFitness.wrongVersion,
      reason: '$detected (needs ${requirements.describe(spec)})',
    );
  }
  return (fitness: ToolFitness.satisfied, reason: null);
}

// ---------------------------------------------------------------------------
// Probing — the IO half.
// ---------------------------------------------------------------------------

class ToolProbe {
  ToolProbe({
    required this.paths,
    required this.manifest,
    required this.requirements,
    ProcessRunner? runner,
    LoginShellPathReader? loginShellPath,
  })  : _run = runner ?? _defaultRunner,
        _loginShellPath = loginShellPath ?? captureLoginShellPath;

  final ToolchainPaths paths;
  final ToolManifest manifest;
  final ToolchainRequirements requirements;

  final ProcessRunner _run;
  final LoginShellPathReader _loginShellPath;
  String? _developerDir;
  bool _developerDirResolved = false;
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
  /// [deep] enumerates *all* candidates, which the Tools Manager wants so it
  /// can show "you also have a host Flutter". The default stops at the first
  /// satisfied candidate per tool: probing everything costs several seconds of
  /// `Process.run`, and this runs before the first frame.
  Future<ToolchainInventory> inventory({bool deep = false}) async {
    final tools = <ToolId, ToolStatus>{};

    // Flutter first: the Serverpod probe needs `dart` on PATH to run a
    // `dart install` launcher, which would otherwise fail with
    // "dart: command not found".
    final flutter = await _probeFlutter(deep: deep);
    tools[ToolId.flutter] = flutter;
    final dartExecutable = flutter.resolved?.facts['dartExecutable'];

    // The rest are independent of each other, so overlap their subprocesses.
    final rest = await Future.wait([
      _probeSimple(manifest[ToolId.git]!, 'git', const ['--version'],
          parse: parseGitVersion, forbidCltShim: true, deep: deep,
          facts: _gitFacts),
      _probeSimple(manifest[ToolId.llvmTools]!, 'otool', const ['--version'],
          parse: parseOtoolVersion, forbidCltShim: true, deep: deep,
          validate: _validateLlvmTools),
      // Left out entirely when the agent is switched off, rather than probed
      // and then filtered: an id that is absent from the inventory cannot be
      // reported missing, cannot be downloaded, and gets no Settings → Tools
      // row, so this one condition covers all three.
      if (kOpenCodeAgentEnabled)
        _probeSimple(manifest[ToolId.opencode]!, 'opencode', const ['--version'],
            parse: parseOpencodeVersion, deep: deep),
      _probeServerpod(manifest[ToolId.serverpodCli]!, dartExecutable,
          deep: deep),
    ]);
    for (final status in rest) {
      tools[status.id] = status;
    }

    return ToolchainInventory(manifest: manifest, tools: tools);
  }

  // -- Flutter --------------------------------------------------------------

  Future<ToolStatus> _probeFlutter({required bool deep}) async {
    final spec = manifest[ToolId.flutter]!;
    final candidates = <ToolCandidate>[];
    var satisfied = false;

    for (final (source, root) in _managedRoots(spec)) {
      if (satisfied && !deep) break;
      final candidate = await _flutterAt(root, source, spec);
      candidates.add(candidate);
      satisfied |= candidate.isSatisfied;
    }
    if (!satisfied || deep) {
      for (final root in await _hostFlutterRoots()) {
        if (satisfied && !deep) break;
        final candidate = await _flutterAt(root, ToolSource.host, spec);
        candidates.add(candidate);
        satisfied |= candidate.isSatisfied;
      }
    }

    return ToolStatus(spec: spec, candidates: candidates);
  }

  Future<ToolCandidate> _flutterAt(
    String root,
    ToolSource source,
    ToolSpec spec,
  ) async {
    final flutterExe = p.join(root, 'bin', 'flutter');
    final dartExe = p.join(root, 'bin', 'cache', 'dart-sdk', 'bin', 'dart');
    final versionFile = File(p.join(root, 'bin', 'cache', 'flutter.version.json'));

    FlutterInfo? info;
    if (await versionFile.exists()) {
      info = FlutterInfo.parse(await versionFile.readAsString());
    }

    final observation = FlutterObservation(
      hasFlutterExecutable: await File(flutterExe).exists(),
      hasDartExecutable: await File(dartExe).exists(),
      hasWebSdk: await Directory(
        p.join(root, 'bin', 'cache', 'flutter_web_sdk'),
      ).exists(),
      info: info,
    );

    final verdict = qualifyFlutter(
      observation: observation,
      spec: spec,
      requirements: requirements,
      isHost: source == ToolSource.host,
    );

    if (verdict.fitness == ToolFitness.notFound) {
      return ToolCandidate.notFound(ToolId.flutter, source);
    }

    final engineVersion = await _readTrimmed(
      p.join(root, 'bin', 'internal', 'engine.version'),
    );

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
        // Only meaningful for an SDK we control — see processEnvironment().
        if (engineVersion != null && source != ToolSource.host)
          'engineVersion': engineVersion,
        if (info != null && info.channel.isNotEmpty) 'channel': info.channel,
      },
    );
  }

  Future<List<String>> _hostFlutterRoots() async {
    final roots = <String>[];
    void add(String? path) {
      if (path == null || path.isEmpty) return;
      final normalized = p.normalize(path);
      if (!roots.contains(normalized)) roots.add(normalized);
    }

    add(Platform.environment['FLUTTER_ROOT']);

    final onPath = await _which('flutter');
    if (onPath != null) {
      // <root>/bin/flutter → <root>
      add(p.dirname(p.dirname(await _resolveSymlink(onPath))));
    }

    final home = Platform.environment['HOME'];
    if (home != null && home.isNotEmpty) {
      add(p.join(home, 'development', 'flutter'));
      add(p.join(home, 'flutter'));
      add(p.join(home, 'fvm', 'default'));
    }
    return roots;
  }

  // -- git / otool / opencode ----------------------------------------------

  Future<ToolStatus> _probeSimple(
    ToolSpec spec,
    String command,
    List<String> versionArgs, {
    required ToolVersion? Function(String output) parse,
    bool forbidCltShim = false,
    required bool deep,
    Future<Map<String, String>> Function(String root, ToolSource source)? facts,
    Future<String?> Function(String root, String executable)? validate,
  }) async {
    final candidates = <ToolCandidate>[];
    var satisfied = false;

    for (final (source, root) in _managedRoots(spec)) {
      if (satisfied && !deep) break;
      final relative = spec.entrypoints[command] ?? command;
      final executable = p.join(root, relative);
      final candidate = await _executableCandidate(
        spec: spec,
        source: source,
        root: root,
        executable: executable,
        versionArgs: versionArgs,
        parse: parse,
        forbidCltShim: forbidCltShim,
        incompleteReason: await validate?.call(root, executable),
        extraFacts: await facts?.call(root, source) ?? const {},
      );
      candidates.add(candidate);
      satisfied |= candidate.isSatisfied;
    }

    if (!satisfied || deep) {
      for (final path in await _hostCandidatePaths(command, forbidCltShim)) {
        if (satisfied && !deep) break;
        final hostRoot = p.dirname(p.dirname(path));
        final candidate = await _executableCandidate(
          spec: spec,
          source: ToolSource.host,
          root: hostRoot,
          executable: path,
          versionArgs: versionArgs,
          parse: parse,
          forbidCltShim: forbidCltShim,
          incompleteReason: await validate?.call(hostRoot, path),
          extraFacts: await facts?.call(hostRoot, ToolSource.host) ?? const {},
        );
        candidates.add(candidate);
        satisfied |= candidate.isSatisfied;
      }
    }

    return ToolStatus(spec: spec, candidates: candidates);
  }

  Future<ToolCandidate> _executableCandidate({
    required ToolSpec spec,
    required ToolSource source,
    required String root,
    required String executable,
    required List<String> versionArgs,
    required ToolVersion? Function(String output) parse,
    required bool forbidCltShim,
    String? incompleteReason,
    Map<String, String> extraFacts = const {},
  }) async {
    final exists = await File(executable).exists();
    final isStub = forbidCltShim && p.dirname(executable) == kCltShimDir;

    ToolVersion? detected;
    if (exists && !isStub && incompleteReason == null) {
      detected = parse(await _runForOutput(executable, versionArgs));
    }

    final verdict = qualifyVersioned(
      exists: exists,
      isStub: isStub,
      detected: detected,
      spec: spec,
      requirements: requirements,
      incompleteReason: incompleteReason,
    );

    if (verdict.fitness == ToolFitness.notFound) {
      return ToolCandidate.notFound(spec.id, source);
    }

    return ToolCandidate(
      id: spec.id,
      source: source,
      fitness: verdict.fitness,
      reason: verdict.reason,
      root: root,
      executable: executable,
      detectedVersion: detected,
      facts: extraFacts,
    );
  }

  /// Host locations for a command, deliberately excluding the CLT shims.
  Future<List<String>> _hostCandidatePaths(
    String command,
    bool forbidCltShim,
  ) async {
    final paths = <String>[];
    void add(String? path) {
      if (path != null && path.isNotEmpty && !paths.contains(path)) {
        paths.add(path);
      }
    }

    if (forbidCltShim) {
      // Never /usr/bin — those are the shims. Go to the real toolchains.
      add('/opt/homebrew/bin/$command');
      add('/usr/local/bin/$command');
      add('/Library/Developer/CommandLineTools/usr/bin/$command');
      final developerDir = await _resolveDeveloperDir();
      if (developerDir != null) {
        add(p.join(developerDir, 'usr', 'bin', command));
        add(p.join(developerDir, 'Toolchains', 'XcodeDefault.xctoolchain',
            'usr', 'bin', command));
      }
    } else {
      add(await _which(command));
      add('/opt/homebrew/bin/$command');
      add('/usr/local/bin/$command');
    }
    return paths;
  }

  /// `xcode-select -p` is a real binary that exits non-zero without prompting
  /// when no developer directory is selected.
  Future<String?> _resolveDeveloperDir() async {
    if (_developerDirResolved) return _developerDir;
    _developerDirResolved = true;
    try {
      final result = await _run('/usr/bin/xcode-select', ['-p']);
      if (result.exitCode == 0) {
        final path = (result.stdout as String).trim();
        if (path.isNotEmpty && await Directory(path).exists()) {
          _developerDir = path;
        }
      }
    } catch (_) {
      // No developer dir; leave null.
    }
    return _developerDir;
  }

  // -- Serverpod ------------------------------------------------------------

  Future<ToolStatus> _probeServerpod(
    ToolSpec spec,
    String? dartExecutable, {
    required bool deep,
  }) async {
    final candidates = <ToolCandidate>[];
    var satisfied = false;

    // The `dart install` form is a shell script that calls bare `dart`.
    final env = <String, String>{
      'PATH': [
        if (dartExecutable != null) p.dirname(dartExecutable),
        '/usr/bin',
        '/bin',
      ].join(':'),
      if (Platform.environment['HOME'] != null)
        'HOME': Platform.environment['HOME']!,
    };

    for (final (source, root) in _managedRoots(spec)) {
      if (satisfied && !deep) break;
      final executable = p.join(root, spec.entrypoints['serverpod'] ?? 'bin/serverpod');
      // The prebuilt bundle finds its sqlite dylibs through an @rpath that
      // resolves to <root>/lib — without it the CLI loads but cannot run.
      final hasLib = await Directory(p.join(root, 'lib')).exists();
      final candidate = await _executableCandidate(
          spec: spec,
          source: source,
          root: root,
          executable: executable,
          versionArgs: const ['--version'],
          parse: parseServerpodVersion,
          forbidCltShim: false,
          incompleteReason: await File(executable).exists() && !hasLib
              ? 'native libraries (lib/) are missing'
              : null,
          extraFacts: {if (hasLib) 'libDir': p.join(root, 'lib')},
      );
      candidates.add(candidate);
      satisfied |= candidate.isSatisfied;
    }

    if (satisfied && !deep) {
      return ToolStatus(spec: spec, candidates: candidates);
    }

    for (final path in await _hostServerpodPaths()) {
      if (satisfied && !deep) break;
      final detected = parseServerpodVersion(
        await _runForOutput(path, const ['--version'], environment: env),
      );
      final verdict = qualifyVersioned(
        exists: true,
        isStub: false,
        detected: detected,
        spec: spec,
        requirements: requirements,
      );
      candidates.add(
        ToolCandidate(
          id: spec.id,
          source: ToolSource.host,
          fitness: verdict.fitness,
          reason: verdict.reason,
          root: p.dirname(p.dirname(path)),
          executable: path,
          detectedVersion: detected,
        ),
      );
      satisfied |= verdict.fitness == ToolFitness.satisfied;
    }

    return ToolStatus(spec: spec, candidates: candidates);
  }

  Future<List<String>> _hostServerpodPaths() async {
    final found = <String>[];
    final home = Platform.environment['HOME'];
    final pubCache = Platform.environment['PUB_CACHE'] ??
        (home == null ? null : p.join(home, '.pub-cache'));
    for (final candidate in [
      // Where `dart install serverpod_cli` puts it, and the first thing to
      // check: the copy in ~/.pub-cache/bin is the one that goes stale, and it
      // was the only location this knew about — so an up-to-date CLI installed
      // the documented way was invisible unless it also sat on PATH.
      if (home != null)
        p.join(home, 'Library', 'Application Support', 'Dart', 'install', 'bin',
            'serverpod'),
      if (pubCache != null) p.join(pubCache, 'bin', 'serverpod'),
      await _which('serverpod'),
    ]) {
      if (candidate == null) continue;
      if (found.contains(candidate)) continue;
      if (await File(candidate).exists()) found.add(candidate);
    }
    return found;
  }

  /// GIT_EXEC_PATH only for a git we ship. A Homebrew or Xcode git finds its
  /// own libexec, and pointing it at ours would break it.
  Future<Map<String, String>> _gitFacts(String root, ToolSource source) async {
    if (source == ToolSource.host) return const {};
    final execPath = p.join(root, 'libexec', 'git-core');
    if (!await Directory(execPath).exists()) return const {};
    return {'gitExecPath': execPath};
  }

  /// Serverpod needs `install_name_tool` as well as `otool`; a tree with only
  /// one of them is a broken install, not a usable one.
  Future<String?> _validateLlvmTools(String root, String executable) async {
    final sibling = p.join(p.dirname(executable), 'install_name_tool');
    if (await File(sibling).exists()) return null;
    return 'install_name_tool is missing next to otool';
  }

  // -- shared helpers -------------------------------------------------------

  /// Where a managed install lives. A tool resolves from here or from the
  /// host; there is no third source.
  List<(ToolSource, String)> _managedRoots(ToolSpec spec) {
    return [(ToolSource.managed, paths.installDirFor(spec))];
  }

  Future<String> _runForOutput(
    String executable,
    List<String> arguments, {
    Map<String, String>? environment,
  }) async {
    // Never execute something that is not a Mach-O binary or a script — a
    // half-downloaded file must not be handed to the OS loader.
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
  /// (`/usr/bin:/bin:/usr/sbin:/sbin`), so a host Flutter or a `dart install`ed
  /// Serverpod CLI resolves to nothing and the user is offered a download for
  /// tools they already have.
  ///
  /// It is deliberately a *fallback*: the shell costs ~80 ms, and on a launch
  /// that already inherited a usable `PATH` — every `make start`, and every
  /// tool found at a well-known location — it never runs at all. The result,
  /// including a failure, is resolved once per probe.
  Future<String?> _which(String command) async {
    final inherited =
        await whichOnPath(command, Platform.environment['PATH']);
    if (inherited != null) return inherited;
    return whichOnPath(command, await _resolveLoginShellPath());
  }

  /// Memoises the *future*, not the value it settles to.
  ///
  /// `inventory()` probes opencode and Serverpod concurrently, and both reach
  /// here. A `bool _resolved` guard would be set by the first caller before its
  /// await, so the second would sail past it and read a field that is still
  /// null — one spawn, and only one of the two tools getting the answer.
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

  Future<String?> _readTrimmed(String path) async {
    try {
      final file = File(path);
      if (!await file.exists()) return null;
      final text = (await file.readAsString()).trim();
      return text.isEmpty ? null : text;
    } catch (_) {
      return null;
    }
  }
}

/// First executable named [command] in the colon-separated [searchPath], or
/// null when there is none.
///
/// Scanned here rather than shelled out to `/usr/bin/which`, which is what this
/// used to do. Every subprocess in [ToolProbe] runs with
/// `includeParentEnvironment: false` so version output cannot be swayed by the
/// user's environment — but `which` with no `PATH` can only ever fail, and it
/// did, silently, for every tool installed somewhere the hardcoded candidate
/// lists do not name. A `dart install`ed Serverpod CLI and a Flutter SDK outside
/// `~/development` were both invisible because of it.
///
/// Top-level and pure so it is testable without a machine that happens to have
/// the tool installed.
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

/// True when [path] starts with a Mach-O magic number. Used before executing
/// anything discovered on the host, so a text shim or a truncated download is
/// never handed to the loader.
Future<bool> isMachO(String path) async {
  try {
    final handle = await File(path).open();
    try {
      final header = await handle.read(4);
      if (header.length < 4) return false;
      final value = header[0] << 24 | header[1] << 16 | header[2] << 8 | header[3];
      final swapped =
          header[3] << 24 | header[2] << 16 | header[1] << 8 | header[0];
      return _machOMagics.contains(value) || _machOMagics.contains(swapped);
    } finally {
      await handle.close();
    }
  } catch (_) {
    return false;
  }
}
