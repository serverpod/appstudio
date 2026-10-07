import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

/// A stand-in for `serverpod runner serve`: the manifest it publishes and the
/// attach socket it serves, speaking the same newline-delimited JSON-RPC.
///
/// Real enough that App Studio's own discovery and client code run against it
/// unchanged — only the runner behind the socket is fake. Commands are
/// recorded in [calls]; [emit] pushes an event to every attached client.
class FakeRunner {
  FakeRunner._(this.serverDir, this.pid, this._server);

  /// Creates a project under a short temp root — a Unix socket address has
  /// to fit 104 bytes, and the system temp dir alone uses half of that.
  static Future<Directory> createProject({String name = 'demo'}) async {
    final root = await Directory('/tmp').createTemp('asr');
    final serverDir = Directory(p.join(root.path, '${name}_server'));
    await serverDir.create(recursive: true);
    await File(p.join(serverDir.path, 'pubspec.yaml')).writeAsString(
      'name: ${name}_server\n'
      'dependencies:\n'
      '  serverpod: 4.1.0-beta.1\n',
    );
    return root;
  }

  static String serverDirOf(Directory projectRoot, {String name = 'demo'}) =>
      p.join(projectRoot.path, '${name}_server');

  /// Starts serving for [serverDir] at [stage], with [snapshot] merged over a
  /// minimal one.
  static Future<FakeRunner> start(
    String serverDir, {
    String stage = 'running',
    int pid = 424242,
    Map<String, Object?> snapshot = const {},
    int protocolVersion = 1,
  }) async {
    final toolDir = Directory(p.join(serverDir, '.dart_tool', 'serverpod'));
    await toolDir.create(recursive: true);
    final socketPath = p.join(toolDir.path, 'tui.sock');
    final stale = File(socketPath);
    if (await stale.exists()) await stale.delete();
    final server = await ServerSocket.bind(
      InternetAddress(socketPath, type: InternetAddressType.unix),
      0,
    );
    final runner = FakeRunner._(serverDir, pid, server)
      ..stage = stage
      .._protocolVersion = protocolVersion
      ..snapshot = {
        'stage': stage,
        'isRunning': stage == 'running',
        'canLaunchFlutterApps': true,
        'serverEntries': <Object?>[],
        'activeOperations': <Object?>[],
        'flutterApps': <Object?>[],
        'flutterLines': <String, Object?>{},
        'runningFlutterApps': <Object?>[],
        'launchingFlutterApps': <Object?>[],
        'flutterAppUrls': <String, Object?>{},
        ...snapshot,
      };
    await runner.writeManifest();
    server.listen(runner._serve);
    return runner;
  }

  final String serverDir;
  final int pid;
  final ServerSocket _server;
  final _clients = <Socket>{};
  final _attached = <Socket>{};
  int _protocolVersion = 1;

  String stage = 'running';
  int? exitCode;
  late Map<String, Object?> snapshot;

  /// Every command received, by method name, snapshot included.
  final calls = <String>[];

  /// Replies by method name. Unlisted methods answer `{}`.
  final replies = <String, Object? Function(Map<String, Object?> params)>{};

  /// Methods that answer with a JSON-RPC error instead.
  final failures = <String, String>{};

  bool get isClosed => _closed;
  bool _closed = false;

  Future<void> writeManifest() => File(
        p.join(serverDir, '.dart_tool', 'serverpod', 'runner.json'),
      ).writeAsString(
        jsonEncode({
          'protocolVersion': _protocolVersion,
          'cliVersion': '4.1.0-beta.1',
          'pid': pid,
          'stage': stage,
          'exitCode': ?exitCode,
          'projectId': 'fake-project',
          'config': {'watch': true, 'flutter': true, 'serverArgs': <Object?>[]},
        }),
      );

  /// Sends an event to every client that has taken a snapshot.
  void emit(Map<String, Object?> event) {
    final line = jsonEncode({
      'jsonrpc': '2.0',
      'method': 'event',
      'params': event,
    });
    for (final client in _attached) {
      client.write('$line\n');
    }
  }

  /// Shuts down the way a runner asked to stop does: announces it, publishes
  /// the exit code, and closes.
  Future<void> stopRunner({int exitCode = 0}) async {
    stage = 'stopping';
    this.exitCode = exitCode;
    emit({'event': 'stage', 'stage': 'stopping', 'exitCode': exitCode});
    await writeManifest();
    await close();
  }

  /// Disappears without a word, leaving its manifest behind — a crash.
  Future<void> crash() => close();

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    for (final client in _clients.toList()) {
      client.destroy();
    }
    await _server.close();
    final socket = File(p.join(serverDir, '.dart_tool', 'serverpod', 'tui.sock'));
    if (await socket.exists()) await socket.delete();
  }

  void _serve(Socket client) {
    _clients.add(client);
    client
        .cast<List<int>>()
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen(
          (line) => _handle(client, line),
          onError: (_) {},
          onDone: () {
            _clients.remove(client);
            _attached.remove(client);
          },
        );
  }

  void _handle(Socket client, String line) {
    final request = jsonDecode(line) as Map<String, Object?>;
    final method = request['method'] as String;
    final id = request['id'];
    final params = Map<String, Object?>.from(
      request['params'] as Map? ?? const {},
    );
    calls.add(method);
    if (id == null) return;

    if (failures[method] case final message?) {
      client.write(
        '${jsonEncode({
              'jsonrpc': '2.0',
              'id': id,
              'error': {'code': -32000, 'message': message},
            })}\n',
      );
      return;
    }

    final Object? result;
    if (method == 'snapshot') {
      _attached.add(client);
      result = snapshot;
    } else {
      result = replies[method]?.call(params) ?? const <String, Object?>{};
    }
    client.write(
      '${jsonEncode({'jsonrpc': '2.0', 'id': id, 'result': result})}\n',
    );
    if (method == 'stop') unawaited(Future(() => stopRunner()));
  }
}

/// A log event as the runner sends it.
Map<String, Object?> logEvent(
  String message, {
  String level = 'info',
  String? error,
  String? stackTrace,
}) =>
    {
      'event': 'log',
      'type': 'log',
      'time': DateTime.now().toUtc().toIso8601String(),
      'level': level,
      'message': message,
      'scope': {'id': 'root', 'label': 'unknown'},
      'error': ?error,
      'stackTrace': ?stackTrace,
    };

/// The one Flutter app a fresh project has.
const demoApp = {
  'id': 'demo',
  'name': 'Demo app',
  'autoLaunch': true,
  'device': 'web-server',
};
