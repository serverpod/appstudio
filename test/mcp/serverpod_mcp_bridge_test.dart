import 'dart:convert';

import 'package:appstudio/mcp/serverpod_mcp_bridge.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('McpToolOutcome', () {
    test('recognises the bridge answering for an absent runner', () {
      // Verbatim from `serverpod mcp-server` 4.0.0-beta.1 with no
      // `serverpod start` behind it. The bridge produces this itself, so it
      // means "nothing to restart", not "the restart failed".
      const outcome = McpToolOutcome(
        isError: true,
        text: 'The server is not running with `serverpod start` for this '
            'project. Ask the user to run `serverpod start` in the project '
            'directory.',
      );

      expect(outcome.isRunnerMissing, isTrue);
    });

    test('a real failure is not mistaken for a missing runner', () {
      const outcome = McpToolOutcome(
        isError: true,
        text: 'Hot restart failed: compilation error in lib/server.dart',
      );

      expect(outcome.isRunnerMissing, isFalse);
    });

    test('success is neither an error nor a missing runner', () {
      const outcome = McpToolOutcome(
        isError: false,
        text: 'Hot restart completed.',
      );

      expect(outcome.isError, isFalse);
      expect(outcome.isRunnerMissing, isFalse);
    });
  });

  group('protocolLinesOnly', () {
    Stream<List<int>> bytes(List<String> lines) =>
        Stream.value(utf8.encode(lines.join('\n')));

    Future<List<String>> filtered(
      List<String> lines, {
      List<String>? noise,
    }) async {
      final out = await ServerpodMcpBridge.protocolLinesOnly(
        bytes(lines),
        onNoise: noise?.add,
      ).toList();
      return out.map((chunk) => utf8.decode(chunk).trimRight()).toList();
    }

    test('passes JSON-RPC lines through unchanged', () async {
      const request = '{"jsonrpc":"2.0","id":1,"result":{"tools":[]}}';

      expect(await filtered([request]), [request]);
    });

    test('drops the CLI update notice that shares stdout', () async {
      // This is not hypothetical: `serverpod`'s pre-command hook writes its
      // update notice to stdout, which is the protocol channel here. One stray
      // line reaching json_rpc_2 is a parse error that kills the connection.
      final noise = <String>[];
      const response = '{"jsonrpc":"2.0","id":1,"result":{}}';
      final kept = await filtered(
        [
          'A new version 4.0.0 of Serverpod is available!',
          response,
          'Run `dart pub global activate serverpod_cli` to upgrade.',
        ],
        noise: noise,
      );

      expect(kept, [response]);
      expect(noise, hasLength(2));
      expect(noise.first, contains('4.0.0'));
    });

    test('keeps blank lines out of the diagnostics', () async {
      final noise = <String>[];
      await filtered(['', '   ', ''], noise: noise);

      expect(noise, isEmpty);
    });

    test('reassembles a message split across chunks', () async {
      // The framing has to survive a pipe that breaks a line in half, which is
      // how a long response actually arrives.
      const response = '{"jsonrpc":"2.0","id":7,"result":{"ok":true}}';
      final split = Stream<List<int>>.fromIterable([
        utf8.encode(response.substring(0, 20)),
        utf8.encode('${response.substring(20)}\n'),
      ]);

      final out = await ServerpodMcpBridge.protocolLinesOnly(split).toList();

      expect(out.map(utf8.decode).join(), '$response\n');
    });
  });
}
