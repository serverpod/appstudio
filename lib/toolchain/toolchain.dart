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
    required this.flutterVersion,
    required this.serverpodCliVersion,
    required this.binPathPrefix,
    required this.serverpodLibDir,
  });

  final bool isBundled;
  final String? flutterRoot;
  final String flutterExecutable;
  final String dartExecutable;
  final String serverpodExecutable;
  final String? flutterVersion;
  final String? serverpodCliVersion;
  final List<String> binPathPrefix;
  final String? serverpodLibDir;

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
    }
    // Full Serverpod CLI bundle ships sqlite dylibs next to the binary.
    if (serverpodLibDir != null) {
      final existing = env['DYLD_LIBRARY_PATH'];
      env['DYLD_LIBRARY_PATH'] = existing == null || existing.isEmpty
          ? serverpodLibDir!
          : '$serverpodLibDir:$existing';
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
    if (flutterVersion == null || serverpodCliVersion == null) return null;

    final flutterRoot = p.join(root, 'flutter', flutterVersion);
    final flutterBin = p.join(flutterRoot, 'bin');
    final wrapperBin = p.join(root, 'bin');
    final serverpodHome = p.join(root, 'serverpod_cli', serverpodCliVersion);
    final serverpodBin = p.join(serverpodHome, 'bin');
    final serverpodLib = p.join(serverpodHome, 'lib');

    final flutterExe = File(p.join(wrapperBin, 'flutter')).existsSync()
        ? p.join(wrapperBin, 'flutter')
        : p.join(flutterBin, 'flutter');
    final dartExe = File(p.join(wrapperBin, 'dart')).existsSync()
        ? p.join(wrapperBin, 'dart')
        : p.join(flutterBin, 'dart');
    final serverpodExe = File(p.join(wrapperBin, 'serverpod')).existsSync()
        ? p.join(wrapperBin, 'serverpod')
        : p.join(serverpodBin, 'serverpod');

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

    return Toolchain._(
      isBundled: true,
      flutterRoot: flutterRoot,
      flutterExecutable: flutterExe,
      dartExecutable: dartExe,
      serverpodExecutable: serverpodExe,
      flutterVersion: flutterVersion,
      serverpodCliVersion: serverpodCliVersion,
      binPathPrefix: [
        wrapperBin,
        flutterBin,
        serverpodBin,
      ],
      serverpodLibDir: serverpodLib,
    );
  }

  static Future<Toolchain> _resolveHost() async {
    final flutter = await _which('flutter') ?? 'flutter';
    final dart = await _which('dart') ?? 'dart';
    final serverpod = await _which('serverpod') ?? 'serverpod';
    return Toolchain._(
      isBundled: false,
      flutterRoot: Platform.environment['FLUTTER_ROOT'],
      flutterExecutable: flutter,
      dartExecutable: dart,
      serverpodExecutable: serverpod,
      flutterVersion: null,
      serverpodCliVersion: null,
      binPathPrefix: const [],
      serverpodLibDir: null,
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
