import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

/// Minimal SSE client for OpenCode `/event`.
class OpenCodeSse {
  OpenCodeSse({http.Client? client}) : _client = client ?? http.Client();

  final http.Client _client;
  http.Client get client => _client;

  StreamSubscription<List<int>>? _sub;
  final _controller = StreamController<Map<String, dynamic>>.broadcast();
  bool _closed = false;

  Stream<Map<String, dynamic>> get events => _controller.stream;

  Future<void> connect(Uri baseUrl) async {
    await disconnect();
    _closed = false;
    final uri = baseUrl.replace(path: '/event');
    final request = http.Request('GET', uri);
    request.headers['Accept'] = 'text/event-stream';
    request.headers['Cache-Control'] = 'no-cache';

    final response = await _client.send(request);
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw StateError('SSE connect failed: HTTP ${response.statusCode}');
    }

    final buffer = StringBuffer();
    _sub = response.stream.listen(
      (chunk) {
        buffer.write(utf8.decode(chunk, allowMalformed: true));
        var text = buffer.toString();
        // Events are separated by blank lines.
        while (true) {
          final idx = text.indexOf('\n\n');
          if (idx < 0) break;
          final block = text.substring(0, idx);
          text = text.substring(idx + 2);
          final event = _parseBlock(block);
          if (event != null && !_controller.isClosed) {
            _controller.add(event);
          }
        }
        buffer
          ..clear()
          ..write(text);
      },
      onError: (Object e, StackTrace st) {
        if (!_controller.isClosed) {
          _controller.addError(e, st);
        }
      },
      onDone: () {
        if (!_closed && !_controller.isClosed) {
          _controller.addError(StateError('SSE stream closed'));
        }
      },
      cancelOnError: false,
    );
  }

  Future<void> disconnect() async {
    _closed = true;
    await _sub?.cancel();
    _sub = null;
  }

  Future<void> dispose() async {
    await disconnect();
    await _controller.close();
  }

  static Map<String, dynamic>? _parseBlock(String block) {
    final dataLines = <String>[];
    for (final rawLine in block.split('\n')) {
      final line = rawLine.endsWith('\r')
          ? rawLine.substring(0, rawLine.length - 1)
          : rawLine;
      if (line.isEmpty || line.startsWith(':')) continue;
      if (line.startsWith('data:')) {
        dataLines.add(line.substring(5).trimLeft());
      }
    }
    if (dataLines.isEmpty) return null;
    final payload = dataLines.join('\n');
    try {
      final decoded = jsonDecode(payload);
      if (decoded is Map<String, dynamic>) return decoded;
      if (decoded is Map) {
        return decoded.map((k, v) => MapEntry(k.toString(), v));
      }
    } catch (_) {}
    return null;
  }
}
