import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dart_mcp/client.dart';
import 'package:dart_mcp/stdio.dart';
import 'package:meta/meta.dart';

/// The tool that recompiles the server, reboots its process and hot-restarts
/// the Flutter app the runner launched. Takes no arguments.
const kHotRestartTool = 'hot_restart';

/// The only resource the bridge publishes, and the one honest answer to "is a
/// `serverpod start` actually on the other end?".
///
/// Its payload is `{"uri": "<vm service uri>"}` while a runner is attached and
/// `{"uri": null, "error": "not-running"}` when there is none — and the latter
/// is *not* flagged as an error result, so the payload has to be read.
const kVmServiceResource = 'serverpod://vm-service';

enum McpBridgeState { stopped, starting, ready }

/// Outcome of a tool call.
///
/// MCP reports tool failures inside the result with `isError`, not as a
/// protocol error, so a failed hot restart arrives here as a normal response.
class McpToolOutcome {
  const McpToolOutcome({required this.isError, required this.text});

  final bool isError;
  final String text;

  /// True when the bridge is up but no `serverpod start` is attached. The
  /// bridge answers this itself, without ever reaching a runner.
  bool get isRunnerMissing => isError && text.contains('is not running');
}

/// A client for `serverpod mcp-server`, the bridge to a live `serverpod start`.
///
/// The bridge speaks MCP over stdio — newline-delimited JSON-RPC 2.0 — and
/// forwards to a unix socket the runner opens at
/// `<serverDir>/.dart_tool/serverpod/mcp.sock`. Nothing has to be enabled on
/// the runner: it opens that socket unconditionally, in both TUI and
/// `--no-tui` mode.
///
/// Deliberately free of Flutter and of [ToolchainController]: it takes the
/// executable and environment it is handed, so it can be driven from a plain
/// Dart script against a real runner. [McpController] owns the policy.
class ServerpodMcpBridge {
  ServerpodMcpBridge({
    required this.serverpodExecutable,
    required this.workingDirectory,
    required this.environment,
  });

  /// Resolved `serverpod` binary. Never a bare command name — see
  /// `Toolchain.unavailableReason`.
  final String serverpodExecutable;

  /// Where the bridge looks for the server package. The same directory
  /// `serverpod start` is spawned in, so both ends run the same auto-detection
  /// and cannot disagree about which project this is.
  final String workingDirectory;

  final Map<String, String> environment;

  /// How long a hot restart may take. The runner applies no timeout of its
  /// own, and the call covers a full recompile plus a process reboot, so this
  /// is generous on purpose — but unbounded would mean a spinner with no way
  /// out.
  static const hotRestartTimeout = Duration(minutes: 3);

  static const _handshakeTimeout = Duration(seconds: 20);
  static const _probeTimeout = Duration(seconds: 10);

  /// Keeps the tail of anything the bridge said that was not protocol, for
  /// error messages. Bounded — this must not grow for the life of a session.
  static const _maxDiagnostics = 4096;

  Process? _process;
  MCPClient? _client;
  ServerConnection? _connection;
  McpBridgeState _state = McpBridgeState.stopped;
  final _diagnostics = StringBuffer();

  McpBridgeState get state => _state;
  bool get isReady => _state == McpBridgeState.ready && _connection != null;

  /// Non-protocol output the bridge produced, newest last. Empty when it has
  /// behaved itself.
  String get diagnostics => _diagnostics.toString().trim();

  /// Spawns the bridge and completes the MCP handshake.
  ///
  /// Throws on failure, leaving nothing running.
  Future<void> start() async {
    if (_state != McpBridgeState.stopped) return;
    _state = McpBridgeState.starting;
    _diagnostics.clear();

    final Process process;
    try {
      process = await Process.start(
        serverpodExecutable,
        // `-q` is a *global* option, so it precedes the command. It matters:
        // the CLI's update notice is written to stdout, which is the protocol
        // channel here, and would otherwise land mid-stream.
        const ['-q', 'mcp-server'],
        workingDirectory: workingDirectory,
        environment: environment,
        runInShell: false,
      );
    } catch (e) {
      _state = McpBridgeState.stopped;
      throw StateError('Could not start serverpod mcp-server: $e');
    }
    _process = process;

    process.stderr.transform(utf8.decoder).listen(_noteDiagnostic);
    unawaited(
      process.exitCode.then((code) {
        if (_process != process) return;
        _noteDiagnostic('serverpod mcp-server exited with code $code');
        _state = McpBridgeState.stopped;
        _process = null;
        _connection = null;
        _client = null;
      }),
    );

    final client = MCPClient(
      Implementation(name: 'App Studio', version: 'dev'),
    );
    _client = client;
    final connection = client.connectServer(
      stdioChannel(
        input: protocolLinesOnly(process.stdout, onNoise: _noteDiagnostic),
        output: process.stdin,
      ),
    );
    _connection = connection;

    try {
      await connection
          .initialize(
            InitializeRequest(
              protocolVersion: ProtocolVersion.latestSupported,
              capabilities: client.capabilities,
              clientInfo: client.implementation,
            ),
          )
          .timeout(_handshakeTimeout);
      connection.notifyInitialized();
    } catch (e) {
      await stop();
      final extra = diagnostics.isEmpty ? '' : '\n$diagnostics';
      throw StateError('serverpod mcp-server did not answer: $e$extra');
    }

    _state = McpBridgeState.ready;
  }

  /// Whether a `serverpod start` is attached right now.
  ///
  /// The bridge stays up and useful with no runner behind it, so being
  /// connected to the bridge is not the same as being able to do anything.
  /// Reads the VM service resource, which is cheap and changes nothing.
  Future<bool> probeRunnerAttached() async {
    final connection = _connection;
    if (!isReady || connection == null) return false;
    try {
      final result = await connection
          .readResource(ReadResourceRequest(uri: kVmServiceResource))
          .timeout(_probeTimeout);
      for (final contents in result.contents) {
        if (!contents.isText) continue;
        final decoded = jsonDecode(
          TextResourceContents.fromMap(contents as Map<String, Object?>).text,
        );
        if (decoded is! Map) continue;
        final uri = decoded['uri'];
        if (uri is String && uri.isNotEmpty) return true;
      }
    } catch (e) {
      _noteDiagnostic('VM service probe failed: $e');
    }
    return false;
  }

  /// Recompiles and reboots the server, then hot-restarts the Flutter app.
  ///
  /// Returns the bridge's own report. A missing runner comes back as an
  /// [McpToolOutcome] with [McpToolOutcome.isRunnerMissing], not an exception.
  Future<McpToolOutcome> hotRestart() async {
    final connection = _connection;
    if (!isReady || connection == null) {
      return const McpToolOutcome(
        isError: true,
        text: 'Not connected to the Serverpod MCP server.',
      );
    }

    try {
      final result = await connection
          .callTool(CallToolRequest(name: kHotRestartTool))
          .timeout(hotRestartTimeout);
      return McpToolOutcome(
        isError: result.isError ?? false,
        text: _textOf(result),
      );
    } on TimeoutException {
      return McpToolOutcome(
        isError: true,
        text: 'Hot restart did not finish within '
            '${hotRestartTimeout.inMinutes} minutes.',
      );
    } catch (e) {
      return McpToolOutcome(isError: true, text: 'Hot restart failed: $e');
    }
  }

  /// Shuts the bridge down, gracefully first.
  ///
  /// The order matters. Closing the protocol channel makes the bridge close
  /// its socket to the runner and exit; killing it outright leaves the runner
  /// writing into a dead socket, which it reports as an internal error with a
  /// stack trace in the user's server log.
  Future<void> stop() async {
    final process = _process;
    final client = _client;
    _process = null;
    _connection = null;
    _client = null;
    _state = McpBridgeState.stopped;

    if (client != null) {
      try {
        await client.shutdown().timeout(const Duration(seconds: 3));
      } catch (_) {}
    }
    if (process == null) return;
    try {
      await process.exitCode.timeout(
        const Duration(seconds: 3),
        onTimeout: () {
          process.kill(ProcessSignal.sigterm);
          return -1;
        },
      );
    } catch (_) {}
  }

  /// Drops anything that is not a JSON object before it reaches the protocol.
  ///
  /// The bridge shares stdout with the CLI's own logging — an update notice is
  /// written there — and one stray line would otherwise be a parse error that
  /// takes the whole connection down. Dropped lines go to [onNoise] so they can
  /// still be reported.
  @visibleForTesting
  static Stream<List<int>> protocolLinesOnly(
    Stream<List<int>> raw, {
    void Function(String line)? onNoise,
  }) {
    return raw
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .where((line) {
          if (line.trimLeft().startsWith('{')) return true;
          if (line.trim().isNotEmpty) onNoise?.call(line);
          return false;
        })
        .map((line) => utf8.encode('$line\n'));
  }

  void _noteDiagnostic(String text) {
    _diagnostics.write(text.endsWith('\n') ? text : '$text\n');
    if (_diagnostics.length <= _maxDiagnostics) return;
    final kept = _diagnostics.toString();
    _diagnostics
      ..clear()
      ..write(kept.substring(kept.length - _maxDiagnostics));
  }

  static String _textOf(CallToolResult result) {
    final parts = <String>[];
    for (final content in result.content) {
      if (content.isText) {
        parts.add(TextContent.fromMap(content as Map<String, Object?>).text);
      }
    }
    return parts.isEmpty ? 'No response from the server.' : parts.join('\n');
  }
}
