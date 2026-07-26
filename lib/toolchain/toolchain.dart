import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

class Toolchain {
  Toolchain._({
    required this.isBundled,
    required this.flutterRoot,
    required this.flutterExecutable,
    required this.dartExecutable,
    required this.serverpodExecutable,
    required this.opencodeExecutable,
    required this.flutterVersion,
    required this.serverpodCliVersion,
    required this.opencodeVersion,
    required this.gitVersion,
    required this.binPathPrefix,
    required this.serverpodLibDir,
    required this.gitHome,
    required this.flutterPrebuiltEngineVersion,
  });

  final bool isBundled;
  final String? flutterRoot;
  final String flutterExecutable;
  final String dartExecutable;
  final String serverpodExecutable;
  final String opencodeExecutable;
  final String? flutterVersion;
  final String? serverpodCliVersion;
  final String? opencodeVersion;
  final String? gitVersion;
  final List<String> binPathPrefix;
  final String? serverpodLibDir;
  final String? gitHome;
  final String? flutterPrebuiltEngineVersion;

  String get badgeLabel {
    if (!isBundled) return 'host';
    final ver = flutterVersion;
    if (ver == null || ver.isEmpty) return 'bundled';
    return 'bundled $ver';
  }

  Map<String, String> processEnvironment() {
    final env = Map<String, String>.from(Platform.environment);
    final pathParts = <String>[
      ...binPathPrefix,
      if (env['PATH'] case final existing?) ...existing.split(':'),
    ];
    env['PATH'] = pathParts.where((e) => e.isNotEmpty).join(':');
    if (flutterRoot != null) {
      env['FLUTTER_ROOT'] = flutterRoot!;
      // serverpod_cli (AOT) resolves the SDK via DART_SDK or by probing `dart`
      // on PATH. Pin explicitly so compile/run never pick a host stub.
      final dartSdk = p.join(flutterRoot!, 'bin', 'cache', 'dart-sdk');
      if (Directory(dartSdk).existsSync()) {
        env['DART_SDK'] = dartSdk;
      }
    }
    // Prefer pinned engine artifacts over git triangulation (needs real git,
    // and avoids Apple's /usr/bin/git CLT stub on target Macs).
    if (flutterPrebuiltEngineVersion != null &&
        flutterPrebuiltEngineVersion!.isNotEmpty) {
      env['FLUTTER_PREBUILT_ENGINE_VERSION'] = flutterPrebuiltEngineVersion!;
    }
    if (gitHome != null) {
      final execPath = p.join(gitHome!, 'libexec', 'git-core');
      if (Directory(execPath).existsSync()) {
        env['GIT_EXEC_PATH'] = execPath;
      }
    }
    // Full Serverpod CLI bundle ships sqlite dylibs next to the binary.
    if (serverpodLibDir != null) {
      final existing = env['DYLD_LIBRARY_PATH'];
      env['DYLD_LIBRARY_PATH'] = existing == null || existing.isEmpty
          ? serverpodLibDir!
          : '$serverpodLibDir:$existing';
    }
    // Isolate pub downloads from a host Flutter install (or missing cache on
    // a clean Mac). Only when running the bundled toolchain.
    if (isBundled) {
      final home = env['HOME'];
      if (home != null && home.isNotEmpty) {
        env['PUB_CACHE'] = p.join(
          home,
          'Library',
          'Application Support',
          'AppStudio',
          'pub-cache',
        );
      }
    }
    env['TERM'] = 'xterm-256color';
    env['COLORTERM'] = 'truecolor';
    env['COLORFGBG'] = '0;15';
    return env;
  }

  static Future<Toolchain> resolve() async {
    final bundled = await _resolveBundled();
    if (bundled != null) return bundled;
    return _resolveHost();
  }

  static Future<Toolchain?> _resolveBundled() async {
    final root = _bundledToolchainRoot();
    if (root == null) return null;

    final activeFile = File(p.join(root, 'active.json'));
    if (!await activeFile.exists()) return null;

    late final Map<String, dynamic> active;
    try {
      active = jsonDecode(await activeFile.readAsString()) as Map<String, dynamic>;
    } catch (_) {
      return null;
    }

    final flutterVersion = active['flutter'] as String?;
    final serverpodCliVersion = active['serverpod_cli'] as String?;
    final opencodeVersion = active['opencode'] as String?;
    final gitVersion = active['git'] as String?;
    if (flutterVersion == null || serverpodCliVersion == null) return null;

    final flutterRoot = p.join(root, 'flutter', flutterVersion);
    final flutterBin = p.join(flutterRoot, 'bin');
    final wrapperBin = p.join(root, 'bin');
    final serverpodHome = p.join(root, 'serverpod_cli', serverpodCliVersion);
    final serverpodBin = p.join(serverpodHome, 'bin');
    final serverpodLib = p.join(serverpodHome, 'lib');

    String? gitHome;
    String? gitBin;
    if (gitVersion != null && gitVersion.isNotEmpty) {
      final candidate = p.join(root, 'git', gitVersion);
      if (File(p.join(candidate, 'bin', 'git')).existsSync()) {
        gitHome = candidate;
        gitBin = p.join(candidate, 'bin');
      }
    }

    // Real otool / install_name_tool — /usr/bin stubs trigger CLT install.
    String? cctoolsBin;
    final cctoolsCandidate = p.join(root, 'cctools', 'bin');
    if (File(p.join(cctoolsCandidate, 'otool')).existsSync() &&
        File(p.join(cctoolsCandidate, 'install_name_tool')).existsSync()) {
      cctoolsBin = cctoolsCandidate;
    }

    // Prefer versioned binaries directly. Wrappers are fine for PATH use, but
    // App Studio spawns tools with [processEnvironment] which already sets
    // FLUTTER_ROOT / PATH / GIT_EXEC_PATH.
    final flutterExe = p.join(flutterBin, 'flutter');
    final dartExe = p.join(flutterBin, 'dart');
    final serverpodExe = p.join(serverpodBin, 'serverpod');

    String? opencodeExe;
    if (opencodeVersion != null && opencodeVersion.isNotEmpty) {
      final bundled = p.join(root, 'opencode', opencodeVersion, 'opencode');
      if (File(bundled).existsSync()) {
        opencodeExe = bundled;
      }
    }

    // Require Flutter + the full Serverpod CLI bundle (bin + lib).
    if (!File(flutterExe).existsSync() || !File(dartExe).existsSync()) {
      return null;
    }
    if (!File(p.join(serverpodBin, 'serverpod')).existsSync()) {
      return null;
    }
    if (!Directory(serverpodLib).existsSync()) {
      return null;
    }

    // OpenCode is optional for bundled resolution — fall back to host PATH.
    opencodeExe ??= await _which('opencode') ?? 'opencode';

    String? engineVersion;
    final engineFile = File(p.join(flutterRoot, 'bin', 'internal', 'engine.version'));
    if (await engineFile.exists()) {
      engineVersion = (await engineFile.readAsString()).trim();
      if (engineVersion.isEmpty) engineVersion = null;
    }

    return Toolchain._(
      isBundled: true,
      flutterRoot: flutterRoot,
      flutterExecutable: flutterExe,
      dartExecutable: dartExe,
      serverpodExecutable: serverpodExe,
      opencodeExecutable: opencodeExe,
      flutterVersion: flutterVersion,
      serverpodCliVersion: serverpodCliVersion,
      opencodeVersion: opencodeVersion,
      gitVersion: gitVersion,
      binPathPrefix: [
        // Real otool / install_name_tool before /usr/bin CLT stubs.
        ?cctoolsBin,
        // Portable git must precede /usr/bin so Apple's CLT stub is never used.
        ?gitBin,
        wrapperBin,
        flutterBin,
        serverpodBin,
      ],
      serverpodLibDir: serverpodLib,
      gitHome: gitHome,
      flutterPrebuiltEngineVersion: engineVersion,
    );
  }

  static Future<Toolchain> _resolveHost() async {
    final flutter = await _which('flutter') ?? 'flutter';
    final dart = await _which('dart') ?? 'dart';
    final serverpod = await _which('serverpod') ?? 'serverpod';
    final opencode = await _which('opencode') ?? 'opencode';
    return Toolchain._(
      isBundled: false,
      flutterRoot: Platform.environment['FLUTTER_ROOT'],
      flutterExecutable: flutter,
      dartExecutable: dart,
      serverpodExecutable: serverpod,
      opencodeExecutable: opencode,
      flutterVersion: null,
      serverpodCliVersion: null,
      opencodeVersion: null,
      gitVersion: null,
      binPathPrefix: const [],
      serverpodLibDir: null,
      gitHome: null,
      flutterPrebuiltEngineVersion: null,
    );
  }

  static String? _bundledToolchainRoot() {
    // AppStudio.app/Contents/MacOS/AppStudio → ../Resources/toolchain
    final exe = File(Platform.resolvedExecutable);
    final contents = exe.parent.parent.path;
    final inApp = p.join(contents, 'Resources', 'toolchain');
    if (_looksLikeToolchain(inApp)) return inApp;

    // Dev / project-level source of truth: <repo>/toolchain
    final projectRoot = _projectRoot();
    if (projectRoot != null) {
      final candidate = p.join(projectRoot, 'toolchain');
      if (_looksLikeToolchain(candidate)) return candidate;
    }

    // Fallback when cwd is the repo root.
    final cwdCandidate = p.normalize(p.join(Directory.current.path, 'toolchain'));
    if (_looksLikeToolchain(cwdCandidate)) return cwdCandidate;
    return null;
  }

  static bool _looksLikeToolchain(String path) {
    return File(p.join(path, 'active.json')).existsSync();
  }

  /// Walk up from the executable / cwd looking for pubspec.yaml (repo root).
  static String? _projectRoot() {
    var dir = Directory.current;
    for (var i = 0; i < 8; i++) {
      if (File(p.join(dir.path, 'pubspec.yaml')).existsSync() &&
          Directory(p.join(dir.path, 'toolchain')).existsSync()) {
        return dir.path;
      }
      final parent = dir.parent;
      if (parent.path == dir.path) break;
      dir = parent;
    }
    return null;
  }

  static Future<String?> _which(String command) async {
    try {
      final result = await Process.run('which', [command]);
      if (result.exitCode != 0) return null;
      final path = (result.stdout as String).trim();
      return path.isEmpty ? null : path;
    } catch (_) {
      return null;
    }
  }
}
