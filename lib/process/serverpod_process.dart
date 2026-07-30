import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import '../preview/preview_phase.dart';
import '../process/dev_session_cleanup.dart';
import '../process/registration_code.dart';
import '../session/project_session.dart';
import '../terminal/studio_terminal.dart';
import '../toolchain/toolchain.dart';

enum ProcessState { idle, starting, running, stopping }

/// Matches Serverpod's progress line for any Flutter app name, e.g.
/// `Connecting to Example app VM service`.
final _vmServiceConnecting = RegExp(
  r'Connecting to .+ VM service',
  caseSensitive: false,
);

final _ansiEscape = RegExp(r'\x1B\[[0-9;]*[A-Za-z]');

final _flutterSdkDep = RegExp(r'sdk:\s*flutter');

final _lineBreak = RegExp(r'\r\n|\r|\n');

/// Cap on a console line that never terminates (e.g. a progress spinner).
const _maxPartialLine = 4096;

class ServerpodProcessController extends ChangeNotifier {
  ServerpodProcessController({
    required this.toolchain,
    required this.session,
    required this.terminal,
  }) {
    session.addListener(_onSessionChanged);
    _onSessionChanged();
  }

  final Toolchain toolchain;
  final ProjectSession session;
  final StudioTerminal terminal;

  ProcessState _state = ProcessState.idle;
  PreviewPhase _phase = PreviewPhase.idle;
  bool _previewReady = false;
  int _previewReloadToken = 0;
  String? _error;
  String? _boundProjectPath;
  int _epoch = 0;
  Timer? _pollTimer;
  VoidCallback? _terminalListener;
  StreamSubscription<String>? _outputSub;
  final _outputBuffer = StringBuffer();
  final _partialLine = StringBuffer();
  bool _scheduledVmServiceReload = false;
  String? _registrationCode;

  ProcessState get state => _state;
  PreviewPhase get phase => _phase;

  /// Web server is accepting connections on :9998 (CEF may load).
  bool get previewReady => _previewReady;

  /// Increments when the preview should reload (DWDS/VM service attach).
  int get previewReloadToken => _previewReloadToken;

  /// True after Serverpod has started connecting to the Flutter VM service.
  bool get hasAttachedFlutter => _scheduledVmServiceReload;

  /// Last process failure message, if any.
  String? get error => _error;

  /// Sign-up code the server last logged, until dismissed or superseded.
  String? get registrationCode => _registrationCode;

  bool get canStart => session.hasProject && _state == ProcessState.idle;
  bool get canStop =>
      _state == ProcessState.running || _state == ProcessState.starting;

  void _onSessionChanged() {
    final path = session.projectPath;
    if (path == null) {
      _boundProjectPath = null;
      unawaited(stop());
      return;
    }
    if (path == _boundProjectPath &&
        (_state == ProcessState.running || _state == ProcessState.starting)) {
      return;
    }
    unawaited(_startForProject(path));
  }

  Future<void> _startForProject(String projectPath) async {
    final epoch = ++_epoch;
    if (canStop) {
      await stop();
    }
    if (epoch != _epoch || session.projectPath != projectPath) return;

    _boundProjectPath = projectPath;
    await start();
  }

  Future<void> start() async {
    final projectPath = session.projectPath;
    if (projectPath == null) return;
    if (_state == ProcessState.starting || _state == ProcessState.running) {
      return;
    }

    _error = null;
    _previewReady = false;
    _scheduledVmServiceReload = false;
    _outputBuffer.clear();
    _partialLine.clear();
    _registrationCode = null;
    _setPhase(ProcessState.starting, PreviewPhase.fetchingDependencies);

    _terminalListener ??= () {
      if (!terminal.isRunning &&
          (_state == ProcessState.running || _state == ProcessState.starting)) {
        _onProcessExited();
      }
    };
    terminal.addListener(_terminalListener!);

    await _outputSub?.cancel();
    _outputSub = terminal.output.listen(_onTerminalOutput);

    final startEpoch = _epoch;
    try {
      // Clear screen once, then show pub get + serverpod in the same log.
      terminal.writeLocal('\x1bc');
      await _ensureDependencies(projectPath);
      if (startEpoch != _epoch || _state != ProcessState.starting) {
        return;
      }

      _setPhase(ProcessState.starting, PreviewPhase.startingServerpod);
      terminal.writeLocal('\r\n==> serverpod start --no-tui\r\n');
      await terminal.spawn(
        executable: toolchain.serverpodExecutable,
        arguments: const ['start', '--no-tui'],
        workingDirectory: projectPath,
        environment: toolchain.processEnvironment(),
        clearScreen: false,
      );
      _setPhase(ProcessState.running, PreviewPhase.waitingForServer);
      _startPolling();
    } catch (e) {
      _error = e.toString();
      _previewReady = false;
      _setPhase(ProcessState.idle, PreviewPhase.failed);
    }
  }

  /// Resolve packages with the bundled Dart/Flutter so target Macs without a
  /// host SDK (and with a stale `.dart_tool` from another machine) still work.
  Future<void> _ensureDependencies(String projectPath) async {
    final env = toolchain.processEnvironment();
    final pubCache = env['PUB_CACHE'];
    if (pubCache != null && pubCache.isNotEmpty) {
      await Directory(pubCache).create(recursive: true);
      terminal.writeLocal('PUB_CACHE=$pubCache\r\n');
    }

    final workspaceRoot = await _findWorkspaceRoot(projectPath);
    final packages = workspaceRoot != null
        ? <String>[workspaceRoot]
        : await _discoverPackages(projectPath);
    if (packages.isEmpty) {
      terminal.writeLocal('No pubspec.yaml packages found under project.\r\n');
      return;
    }

    if (workspaceRoot != null) {
      terminal.writeLocal(
        'Dart workspace: ${p.basename(workspaceRoot)}\r\n',
      );
    }

    for (final pkg in packages) {
      if (_state != ProcessState.starting) return;
      final useFlutter = workspaceRoot != null
          ? await _workspaceHasFlutterPackage(workspaceRoot)
          : await _isFlutterPackage(pkg);
      final exe =
          useFlutter ? toolchain.flutterExecutable : toolchain.dartExecutable;
      final label = p.basename(pkg);
      terminal.writeLocal(
        '\r\n==> ${useFlutter ? 'flutter' : 'dart'} pub get ($label)\r\n',
      );
      final process = await Process.start(
        exe,
        const ['pub', 'get'],
        workingDirectory: pkg,
        environment: env,
      );
      final out = process.stdout.transform(utf8.decoder).listen((chunk) {
        terminal.writeLocal(chunk.replaceAll('\n', '\r\n'));
      });
      final err = process.stderr.transform(utf8.decoder).listen((chunk) {
        terminal.writeLocal(chunk.replaceAll('\n', '\r\n'));
      });
      final code = await process.exitCode;
      await out.cancel();
      await err.cancel();
      if (code != 0) {
        throw Exception(
          'pub get failed in $label (exit $code). '
          'Check the Server logs tab — network may be required on first run.',
        );
      }
    }

    await _assertServerpodPackageResolved(
      workspaceRoot ?? projectPath,
    );

    // serverpod start reuses `.dart_tool/serverpod/server.dill` when sources
    // look unchanged — it does *not* invalidate on package_config changes.
    // After a fresh pub get (new PUB_CACHE paths), force a recompile.
    await _invalidateServerpodCompileCaches(
      workspaceRoot ?? projectPath,
    );
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
    final packages = await _discoverPackages(workspaceRoot);
    for (final pkg in packages) {
      if (await _isFlutterPackage(pkg)) return true;
    }
    return false;
  }

  Future<List<String>> _discoverPackages(String root) async {
    final found = <String>[];
    Future<void> consider(String dir) async {
      if (await File(p.join(dir, 'pubspec.yaml')).exists()) {
        found.add(dir);
      }
    }

    await consider(root);
    final rootDir = Directory(root);
    if (!await rootDir.exists()) return found;

    await for (final entity in rootDir.list(followLinks: false)) {
      if (entity is! Directory) continue;
      final name = p.basename(entity.path);
      if (name.startsWith('.')) continue;
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
  Future<void> _assertServerpodPackageResolved(String resolutionRoot) async {
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
      config = jsonDecode(await configFile.readAsString()) as Map<String, dynamic>;
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

    final serverpodLib = File(p.join(rootPath, 'lib', 'serverpod.dart'));
    if (!await serverpodLib.exists()) {
      throw Exception(
        'package:serverpod is incomplete (missing lib/serverpod.dart) at:\n'
        '  $rootPath',
      );
    }

    terminal.writeLocal(
      'Resolved package:serverpod → $rootPath\r\n',
    );
  }

  Future<void> _invalidateServerpodCompileCaches(String root) async {
    final packages = await _discoverPackages(root);
    for (final pkg in packages) {
      final cacheDir = Directory(p.join(pkg, '.dart_tool', 'serverpod'));
      if (!await cacheDir.exists()) continue;
      await cacheDir.delete(recursive: true);
      terminal.writeLocal(
        'Cleared ${p.basename(pkg)}/.dart_tool/serverpod '
        '(force server recompile)\r\n',
      );
    }
  }

  Future<void> stop() async {
    if (_state == ProcessState.idle || _state == ProcessState.stopping) return;
    _setPhase(ProcessState.stopping, PreviewPhase.stopping);
    _stopPolling();
    await terminal.stop();
    _onProcessExited();
  }

  /// Called by the preview pane once the Flutter web app is actually running.
  ///
  /// Ignored until DWDS has attached at least once — the first CEF load is
  /// usually a blank page until the VM-service reload completes.
  void markPreviewLive() {
    if (_state != ProcessState.running || !_previewReady) return;
    if (_phase == PreviewPhase.ready) return;
    // Stay on loading/connecting overlay until attach + reload have happened.
    if (!_scheduledVmServiceReload) return;
    _phase = PreviewPhase.ready;
    _error = null;
    notifyListeners();
  }

  void _onProcessExited() {
    final wasStopping = _state == ProcessState.stopping;
    _stopPolling();
    unawaited(_outputSub?.cancel());
    _outputSub = null;
    _previewReady = false;
    _scheduledVmServiceReload = false;
    _outputBuffer.clear();
    _partialLine.clear();
    _registrationCode = null;
    if (wasStopping) {
      _error = null;
      _setPhase(ProcessState.idle, PreviewPhase.idle);
      return;
    }
    // Unexpected exit while starting/running.
    _error ??= 'Serverpod stopped unexpectedly';
    _setPhase(ProcessState.idle, PreviewPhase.failed);
  }

  @visibleForTesting
  void ingestOutput(String chunk) => _onTerminalOutput(chunk);

  void _onTerminalOutput(String chunk) {
    _scanLines(chunk);

    // Only buffer until the match lands — the server logs for the whole session
    // otherwise, and this is the only thing the buffer is for.
    if (_scheduledVmServiceReload) return;
    _outputBuffer.write(chunk);

    final plain = _outputBuffer.toString().replaceAll(_ansiEscape, '');
    if (!_vmServiceConnecting.hasMatch(plain)) return;

    _scheduledVmServiceReload = true;
    _outputBuffer.clear();
    _previewReloadToken++;
    _phase = PreviewPhase.connecting;
    notifyListeners();
  }

  /// Reassembles whole console lines across PTY chunks and inspects each one.
  void _scanLines(String chunk) {
    _partialLine.write(chunk.replaceAll(_ansiEscape, ''));
    final lines = _partialLine.toString().split(_lineBreak);
    // The tail has no line break yet, so it may still be growing.
    final tail = lines.removeLast();
    _partialLine
      ..clear()
      ..write(
        tail.length > _maxPartialLine
            ? tail.substring(tail.length - _maxPartialLine)
            : tail,
      );

    for (final line in lines) {
      final code = parseRegistrationCode(line);
      if (code != null) {
        _registrationCode = code;
        notifyListeners();
      }
    }
  }

  /// Clears the registration code banner (user dismissed it).
  void dismissRegistrationCode() {
    if (_registrationCode == null) return;
    _registrationCode = null;
    notifyListeners();
  }

  void _startPolling() {
    _stopPolling();
    _pollTimer = Timer.periodic(const Duration(milliseconds: 750), (_) async {
      if (_state != ProcessState.running) return;
      final ready = await _tcpReady(kPreviewPort);
      if (ready && !_previewReady) {
        _previewReady = true;
        _phase = PreviewPhase.loadingApp;
        notifyListeners();
      }
    });
  }

  void _stopPolling() {
    _pollTimer?.cancel();
    _pollTimer = null;
  }

  Future<bool> _tcpReady(int port) async {
    try {
      final socket = await Socket.connect(
        '127.0.0.1',
        port,
        timeout: const Duration(milliseconds: 400),
      );
      await socket.close();
      return true;
    } catch (_) {
      return false;
    }
  }

  void _setPhase(ProcessState state, PreviewPhase phase) {
    _state = state;
    _phase = phase;
    notifyListeners();
  }

  @override
  void dispose() {
    session.removeListener(_onSessionChanged);
    _stopPolling();
    unawaited(_outputSub?.cancel());
    if (_terminalListener != null) {
      terminal.removeListener(_terminalListener!);
    }
    if (canStop) {
      unawaited(stop());
    }
    super.dispose();
  }
}
