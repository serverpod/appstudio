import 'dart:convert';

import 'package:http/http.dart' as http;

class OpenCodeProviderInfo {
  const OpenCodeProviderInfo({
    required this.id,
    required this.name,
    this.models = const {},
  });

  final String id;
  final String name;
  final Map<String, String> models; // modelId -> display name

  factory OpenCodeProviderInfo.fromJson(Map<String, dynamic> json) {
    final modelsRaw = json['models'];
    final models = <String, String>{};
    if (modelsRaw is Map) {
      for (final entry in modelsRaw.entries) {
        final id = entry.key.toString();
        final value = entry.value;
        if (value is Map && value['name'] != null) {
          models[id] = value['name'].toString();
        } else {
          models[id] = id;
        }
      }
    }
    return OpenCodeProviderInfo(
      id: (json['id'] ?? '').toString(),
      name: (json['name'] ?? json['id'] ?? '').toString(),
      models: models,
    );
  }
}

class OpenCodeClient {
  OpenCodeClient({http.Client? httpClient})
      : _http = httpClient ?? http.Client();

  final http.Client _http;
  Uri? _baseUrl;

  Uri? get baseUrl => _baseUrl;

  void attach(Uri baseUrl) {
    _baseUrl = baseUrl;
  }

  void detach() {
    _baseUrl = null;
  }

  Future<bool> health() async {
    final res = await _get('/global/health');
    return res.statusCode == 200 && res.body.contains('healthy');
  }

  Future<String> createSession({String? title}) async {
    final res = await _post('/session', body: {
      'title': ?title,
    });
    final json = _decodeMap(res);
    final id = json['id']?.toString();
    if (id == null || id.isEmpty) {
      throw StateError('createSession: missing id');
    }
    return id;
  }

  Future<void> promptAsync({
    required String sessionId,
    required String text,
    String? providerId,
    String? modelId,
    String? agent,
  }) async {
    final body = <String, dynamic>{
      'parts': [
        {'type': 'text', 'text': text},
      ],
    };
    if (agent != null && agent.isNotEmpty) {
      body['agent'] = agent;
    }
    if (providerId != null &&
        providerId.isNotEmpty &&
        modelId != null &&
        modelId.isNotEmpty) {
      body['model'] = {
        'providerID': providerId,
        'modelID': modelId,
      };
    }
    final res = await _post(
      '/session/$sessionId/prompt_async',
      body: body,
      acceptEmpty: true,
    );
    if (res.statusCode != 204 &&
        (res.statusCode < 200 || res.statusCode >= 300)) {
      throw StateError('prompt_async failed: ${res.statusCode} ${res.body}');
    }
  }

  Future<void> abort(String sessionId) async {
    await _post('/session/$sessionId/abort', body: const {});
  }

  /// [reply] must be `once`, `always` or `reject` — the server rejects
  /// anything else with HTTP 400 and the agent stays blocked.
  Future<void> replyPermission({
    required String permissionId,
    required String reply,
  }) async {
    await _post('/permission/$permissionId/reply', body: {'reply': reply});
  }

  /// [answers] holds one entry per question, each a list of selected labels.
  Future<void> replyQuestion({
    required String requestId,
    required List<List<String>> answers,
  }) async {
    await _post('/question/$requestId/reply', body: {'answers': answers});
  }

  Future<void> rejectQuestion(String requestId) async {
    await _post('/question/$requestId/reject', body: const {});
  }

  Future<void> setAuthApiKey(String providerId, String key) async {
    final res = await _put('/auth/$providerId', body: {
      'type': 'api',
      'key': key,
    });
    if (res.statusCode < 200 || res.statusCode >= 300) {
      throw StateError('setAuth failed: ${res.statusCode} ${res.body}');
    }
  }

  Future<({List<OpenCodeProviderInfo> all, List<String> connected})>
      listProviders() async {
    final res = await _get('/provider');
    final json = _decodeMap(res);
    final allRaw = json['all'];
    final all = <OpenCodeProviderInfo>[];
    if (allRaw is List) {
      for (final item in allRaw) {
        if (item is Map<String, dynamic>) {
          all.add(OpenCodeProviderInfo.fromJson(item));
        } else if (item is Map) {
          all.add(OpenCodeProviderInfo.fromJson(
            item.map((k, v) => MapEntry(k.toString(), v)),
          ));
        }
      }
    }
    final connectedRaw = json['connected'];
    final connected = <String>[];
    if (connectedRaw is List) {
      for (final c in connectedRaw) {
        connected.add(c.toString());
      }
    }
    return (all: all, connected: connected);
  }

  Future<List<({String providerId, String modelId, String label})>>
      listModels() async {
    final res = await _get('/config/providers');
    final json = _decodeMap(res);
    final providers = json['providers'];
    final out = <({String providerId, String modelId, String label})>[];
    if (providers is List) {
      for (final p in providers) {
        if (p is! Map) continue;
        final map = p.map((k, v) => MapEntry(k.toString(), v));
        final providerId = (map['id'] ?? '').toString();
        final providerName = (map['name'] ?? providerId).toString();
        final models = map['models'];
        if (models is Map) {
          for (final entry in models.entries) {
            final modelId = entry.key.toString();
            var modelName = modelId;
            final value = entry.value;
            if (value is Map && value['name'] != null) {
              modelName = value['name'].toString();
            }
            out.add((
              providerId: providerId,
              modelId: modelId,
              label: '$providerName / $modelName',
            ));
          }
        }
      }
    }
    return out;
  }

  Future<void> setDefaultModel(String providerId, String modelId) async {
    final res = await _patch('/config', body: {
      'model': '$providerId/$modelId',
    });
    if (res.statusCode < 200 || res.statusCode >= 300) {
      throw StateError('setDefaultModel failed: ${res.statusCode} ${res.body}');
    }
  }

  void close() {
    _http.close();
  }

  Future<http.Response> _get(String path) async {
    final base = _requireBase();
    final res = await _http
        .get(base.replace(path: path))
        .timeout(const Duration(seconds: 15));
    return res;
  }

  Future<http.Response> _post(
    String path, {
    required Map<String, dynamic> body,
    bool acceptEmpty = false,
  }) async {
    final base = _requireBase();
    final res = await _http
        .post(
          base.replace(path: path),
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode(body),
        )
        .timeout(const Duration(seconds: 30));
    if (!acceptEmpty && (res.statusCode < 200 || res.statusCode >= 300)) {
      throw StateError('POST $path failed: ${res.statusCode} ${res.body}');
    }
    return res;
  }

  Future<http.Response> _put(
    String path, {
    required Map<String, dynamic> body,
  }) async {
    final base = _requireBase();
    return _http
        .put(
          base.replace(path: path),
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode(body),
        )
        .timeout(const Duration(seconds: 15));
  }

  Future<http.Response> _patch(
    String path, {
    required Map<String, dynamic> body,
  }) async {
    final base = _requireBase();
    return _http
        .patch(
          base.replace(path: path),
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode(body),
        )
        .timeout(const Duration(seconds: 15));
  }

  Uri _requireBase() {
    final base = _baseUrl;
    if (base == null) {
      throw StateError('OpenCodeClient is not attached to a server');
    }
    return base;
  }

  Map<String, dynamic> _decodeMap(http.Response res) {
    if (res.statusCode < 200 || res.statusCode >= 300) {
      throw StateError('HTTP ${res.statusCode}: ${res.body}');
    }
    if (res.body.isEmpty) return {};
    final decoded = jsonDecode(res.body);
    if (decoded is Map<String, dynamic>) return decoded;
    if (decoded is Map) {
      return decoded.map((k, v) => MapEntry(k.toString(), v));
    }
    throw StateError('Expected JSON object');
  }
}
