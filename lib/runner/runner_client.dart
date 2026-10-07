import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:json_rpc_2/json_rpc_2.dart' as rpc;
import 'package:stream_channel/stream_channel.dart';

import 'runner_discovery.dart';
import 'runner_protocol.dart';

/// One connection to a runner's attach socket.
///
/// JSON-RPC 2.0 over newline-delimited JSON, through `package:json_rpc_2` —
/// the package the runner serves it with, so the framing and error shapes
/// cannot drift. Every call passes an object for params, even an empty one:
/// the runner's handlers read named params, and `json_rpc_2` rejects an absent
/// one there.
///
/// This class is the wire and nothing else. It does not reconnect, and it does
/// not keep state — [RunnerLog] mirrors the history, and the process controller
/// decides what a dropped connection means.
class RunnerClient {
  RunnerClient._(this._socket, this._peer);

  /// Connects to the socket at [socketPath]. Nothing is attached yet: a client
  /// that never calls [attach] only sends commands and arms nothing.
  static Future<RunnerClient> connect(
    String socketPath, {
    Duration timeout = const Duration(seconds: 2),
  }) async {
    final socket = await connectRunnerSocket(socketPath, timeout: timeout);
    final peer = rpc.Peer(_lineChannel(socket));
    final client = RunnerClient._(socket, peer);
    peer.registerMethod('event', client._onEvent);
    unawaited(
      peer.listen().then((_) {}, onError: (_) {}).whenComplete(client._onDone),
    );
    return client;
  }

  final Socket _socket;
  final rpc.Peer _peer;
  final _events = StreamController<RunnerEvent>.broadcast(sync: true);
  final _done = Completer<void>();

  /// Events that landed while the snapshot request was in flight. The runner
  /// subscribes a client the moment it computes the snapshot, so an event can
  /// overtake the reply on the wire; it is applied after, as the CLI's own
  /// client does.
  List<RunnerEvent>? _held;

  /// Every change after the snapshot, in order.
  Stream<RunnerEvent> get events => _events.stream;

  /// Completes when the connection closes, from either end.
  Future<void> get done => _done.future;

  bool get isClosed => _done.isCompleted;

  /// Takes the snapshot, hands it to [onSnapshot], then starts delivering
  /// [events] — including any that overtook the reply.
  ///
  /// The first snapshot request a runner ever answers is what arms its Flutter
  /// auto-launch: from here on, `auto_launch` apps start.
  Future<void> attach(
    void Function(RunnerSnapshot snapshot) onSnapshot, {
    Duration timeout = const Duration(seconds: 10),
  }) async {
    final held = _held = [];
    try {
      final reply = await _peer
          .sendRequest('snapshot', const <String, Object?>{})
          .timeout(timeout);
      onSnapshot(
        RunnerSnapshot.fromJson(Map<String, Object?>.from(reply as Map)),
      );
    } finally {
      _held = null;
    }
    held.forEach(_emit);
  }

  Future<void> hotReload() => _call('hotReload');

  Future<void> hotRestart() => _call('hotRestart');

  Future<void> retryStart() => _call('retryStart');

  /// Asks the runner to shut down. It answers at once and stops after, so the
  /// connection closing is what says it has gone.
  Future<void> stop({Duration timeout = const Duration(seconds: 5)}) =>
      _call('stop').timeout(timeout);

  Future<void> applyMigrations() => _call('applyMigrations');

  Future<MigrationResult> createMigration({String? tag, bool force = false}) =>
      _call('createMigration', {'tag': ?tag, 'force': force})
          .then(_migrationResult);

  Future<MigrationResult> createRepairMigration({
    String? tag,
    bool force = false,
  }) =>
      _call('createRepairMigration', {'tag': ?tag, 'force': force})
          .then(_migrationResult);

  Future<void> launchFlutterApp(String appId) =>
      _call('launchFlutterApp', {'appId': appId});

  Future<void> restartFlutterApp(String appId) =>
      _call('restartFlutterApp', {'appId': appId});

  Future<void> stopFlutterApp(String appId) =>
      _call('stopFlutterApp', {'appId': appId});

  /// Detaches. The runner keeps running.
  Future<void> close() async {
    try {
      await _peer.close();
    } catch (_) {}
    _socket.destroy();
    _onDone();
  }

  Future<Object?> _call(String method, [Map<String, Object?>? params]) {
    if (isClosed) {
      return Future.error(
        const RunnerConnectionException('The runner is not connected.'),
      );
    }
    return _peer
        .sendRequest(method, params ?? const <String, Object?>{})
        .catchError((Object e) {
      throw switch (e) {
        rpc.RpcException(:final message) => RunnerConnectionException(message),
        _ => const RunnerConnectionException(
            'The runner closed the connection.',
          ),
      };
    }, test: (e) => e is rpc.RpcException || e is StateError);
  }

  void _onEvent(rpc.Parameters params) {
    final value = params.value;
    if (value is! Map) return;
    final event = RunnerEvent.fromJson(Map<String, Object?>.from(value));
    if (event == null) return;
    final held = _held;
    if (held != null) {
      held.add(event);
    } else {
      _emit(event);
    }
  }

  void _emit(RunnerEvent event) {
    if (!_events.isClosed) _events.add(event);
  }

  void _onDone() {
    if (_done.isCompleted) return;
    _done.complete();
    unawaited(_events.close());
  }
}

/// A command the runner refused or could not receive.
class RunnerConnectionException implements Exception {
  const RunnerConnectionException(this.message);

  final String message;

  @override
  String toString() => message;
}

MigrationResult _migrationResult(Object? reply) => MigrationResult.fromJson(
      reply is Map ? Map<String, Object?>.from(reply) : const {},
    );

/// [socket] as a channel of lines, which is the runner's framing.
StreamChannel<String> _lineChannel(Socket socket) {
  final incoming = socket
      .cast<List<int>>()
      .transform(utf8.decoder)
      .transform(const LineSplitter())
      // A dropped peer raises a socket error that nothing awaits.
      .handleError((_) {}, test: (e) => e is SocketException);

  final outgoing = StreamController<String>();
  outgoing.stream.listen(
    (line) {
      try {
        socket.write('$line\n');
      } on SocketException {
        // The runner has already gone; `done` reports it.
      }
    },
    onDone: () => socket.close().catchError((_) => socket),
  );
  unawaited(socket.done.catchError((_) {}));
  return StreamChannel<String>(incoming, outgoing.sink);
}
