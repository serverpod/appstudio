import 'dart:convert';

import 'package:http/http.dart' as http;

/// Delivers one already-built event payload. The seam tests replace.
abstract class AnalyticsTransport {
  Future<void> send(Map<String, Object?> payload);

  /// Release any underlying resources.
  void close() {}
}

/// PostHog's single-event capture endpoint.
///
/// Mirrors `PostHogAnalytics` in `package:cli_tools`, which both Serverpod
/// CLIs send through: the EU host, `POST /capture/`, a JSON body carrying the
/// project key, and a short timeout so a slow network never holds anything
/// up. Errors are the caller's to swallow — this class only knows how to post.
class PostHogTransport extends AnalyticsTransport {
  PostHogTransport({
    required this._projectApiKey,
    http.Client? client,
    String host = defaultHost,
    this.timeout = const Duration(seconds: 2),
  }) : _client = client ?? http.Client(),
       _endpoint = Uri.parse('$host/capture/');

  static const defaultHost = 'https://eu.i.posthog.com';

  final String _projectApiKey;
  final http.Client _client;
  final Uri _endpoint;
  final Duration timeout;

  @override
  Future<void> send(Map<String, Object?> payload) async {
    await _client
        .post(
          _endpoint,
          headers: const {'Content-Type': 'application/json'},
          body: jsonEncode({'api_key': _projectApiKey, ...payload}),
        )
        .timeout(timeout);
  }

  @override
  void close() => _client.close();
}
