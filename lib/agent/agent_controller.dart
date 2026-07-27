import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../platform/studio_notifications.dart';
import '../process/serverpod_process.dart';
import '../session/project_session.dart';
import '../toolchain/toolchain.dart';
import 'agent_transcript.dart';
import 'opencode_auth_store.dart';
import 'opencode_client.dart';
import 'opencode_serve.dart';
import 'opencode_sse.dart';

enum AgentConnectionState {
  idle,
  starting,
  ready,
  busy,
  error,
}

/// Chat mode shown in the composer; maps to OpenCode agent names.
enum AgentChatMode {
  agent,
  plan;

  String get label => switch (this) {
        agent => 'Agent',
        plan => 'Plan or Ask',
      };

  /// OpenCode agent id (`build` is the default full-access agent).
  String get apiName => switch (this) {
        agent => 'build',
        plan => 'plan',
      };

  static AgentChatMode? tryParse(String? value) {
    return switch (value) {
      'agent' => AgentChatMode.agent,
      'plan' => AgentChatMode.plan,
      _ => null,
    };
  }
}

class AgentModelOption {
  const AgentModelOption({
    required this.providerId,
    required this.modelId,
    required this.label,
  });

  final String providerId;
  final String modelId;
  final String label;

  String get value => '$providerId/$modelId';
}

/// OpenCode Zen free tier; preferred when listed and no model is saved yet.
const kPreferredDefaultModelId = 'deepseek-v4-flash-free';

AgentModelOption? pickPreferredDefaultModel(List<AgentModelOption> models) {
  if (models.isEmpty) return null;

  for (final providerId in ['opencode', 'deepseek']) {
    for (final m in models) {
      if (m.providerId == providerId && m.modelId == kPreferredDefaultModelId) {
        return m;
      }
    }
  }

  for (final m in models) {
    if (m.modelId == kPreferredDefaultModelId) return m;
  }

  for (final m in models) {
    if (m.label.toLowerCase().contains('deepseek v4 flash free')) {
      return m;
    }
  }

  return null;
}

/// Owns OpenCode serve lifecycle, SSE transcript, and chat actions.
class AgentController extends ChangeNotifier {
  AgentController({
    required this.toolchain,
    required this.session,
    required this.process,
    OpenCodeAuthStore? authStore,
  })  : _authStore = authStore ?? OpenCodeAuthStore(),
        _serve = OpenCodeServe(toolchain: toolchain),
        _client = OpenCodeClient(),
        _sse = OpenCodeSse() {
    session.addListener(_onSessionOrProcessChanged);
    process.addListener(_onSessionOrProcessChanged);
    unawaited(_loadPrefs());
    _onSessionOrProcessChanged();
  }

  final Toolchain toolchain;
  final ProjectSession session;
  final ServerpodProcessController process;
  final OpenCodeAuthStore _authStore;
  final OpenCodeServe _serve;
  final OpenCodeClient _client;
  final OpenCodeSse _sse;

  static const _prefsModelKey = 'agent.default_model';
  static const _prefsModeKey = 'agent.chat_mode';

  AgentConnectionState _connection = AgentConnectionState.idle;
  String? _statusMessage;
  String? _error;
  String? _sessionId;
  String? _boundProjectPath;
  final List<AgentChatMessage> _messages = [];
  final List<AgentPermissionPart> _pendingPermissions = [];
  List<String> _connectedProviders = [];
  List<AgentModelOption> _availableModels = [];
  String? _defaultModel; // provider/model
  AgentChatMode _mode = AgentChatMode.agent;
  StreamSubscription<Map<String, dynamic>>? _sseSub;
  int _epoch = 0;
  VoidCallback? _onOpenSettings;

  AgentConnectionState get connection => _connection;
  String? get statusMessage => _statusMessage;
  String? get error => _error;
  List<AgentChatMessage> get messages => List.unmodifiable(_messages);
  List<AgentPermissionPart> get pendingPermissions =>
      List.unmodifiable(_pendingPermissions);
  List<String> get connectedProviders =>
      List.unmodifiable(_connectedProviders);
  List<AgentModelOption> get availableModels =>
      List.unmodifiable(_availableModels);
  String? get defaultModel => _defaultModel;
  AgentChatMode get mode => _mode;
  bool get isBusy => _connection == AgentConnectionState.busy;
  bool get canSend =>
      session.hasProject &&
      process.previewReady &&
      _connection == AgentConnectionState.ready &&
      _connectedProviders.isNotEmpty;
  bool get hasProviders => _connectedProviders.isNotEmpty;
  OpenCodeClient get client => _client;
  OpenCodeAuthStore get authStore => _authStore;
  bool get isServeRunning => _serve.isRunning;
  ProjectSession get projectSession => session;

  String? get defaultModelLabel {
    final value = _defaultModel;
    if (value == null) return null;
    for (final m in _availableModels) {
      if (m.value == value) return m.label;
    }
    final slash = value.indexOf('/');
    if (slash >= 0 && slash < value.length - 1) {
      return value.substring(slash + 1);
    }
    return value;
  }

  void setOpenSettingsHandler(VoidCallback? handler) {
    _onOpenSettings = handler;
  }

  void openSettings() => _onOpenSettings?.call();

  Future<void> _loadPrefs() async {
    final prefs = await SharedPreferences.getInstance();
    _defaultModel = prefs.getString(_prefsModelKey);
    _mode = AgentChatMode.tryParse(prefs.getString(_prefsModeKey)) ??
        AgentChatMode.agent;
    notifyListeners();
  }

  Future<void> setMode(AgentChatMode mode) async {
    if (_mode == mode) return;
    _mode = mode;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_prefsModeKey, mode.name);
  }

  Future<void> setDefaultModel(String? providerModel) async {
    _defaultModel = providerModel;
    final prefs = await SharedPreferences.getInstance();
    if (providerModel == null || providerModel.isEmpty) {
      await prefs.remove(_prefsModelKey);
    } else {
      await prefs.setString(_prefsModelKey, providerModel);
      if (_client.baseUrl != null) {
        final parts = providerModel.split('/');
        if (parts.length >= 2) {
          try {
            await _client.setDefaultModel(parts.first, parts.sublist(1).join('/'));
          } catch (_) {}
        }
      }
    }
    notifyListeners();
  }

  void _onSessionOrProcessChanged() {
    final path = session.projectPath;
    if (path == null) {
      unawaited(_teardown(clearMessages: true));
      return;
    }

    if (!process.previewReady) {
      if (_connection != AgentConnectionState.idle || _serve.isRunning) {
        unawaited(_teardown(clearMessages: false));
      }
      return;
    }

    if (path == _boundProjectPath &&
        (_connection == AgentConnectionState.ready ||
            _connection == AgentConnectionState.busy ||
            _connection == AgentConnectionState.starting)) {
      return;
    }
    unawaited(_startForProject(path));
  }

  Future<void> _startForProject(String projectPath) async {
    final epoch = ++_epoch;
    await _teardown(clearMessages: true, bumpEpoch: false);
    if (epoch != _epoch) return;

    _boundProjectPath = projectPath;
    _connection = AgentConnectionState.starting;
    _statusMessage = 'Starting agent…';
    _error = null;
    notifyListeners();

    try {
      final base = await _serve.start(projectPath);
      if (epoch != _epoch) return;
      _client.attach(base);
      await _sse.connect(base);
      if (epoch != _epoch) return;
      await _sseSub?.cancel();
      _sseSub = _sse.events.listen(
        _onEvent,
        onError: (Object e) {
          if (epoch != _epoch) return;
          _error = e.toString();
          _connection = AgentConnectionState.error;
          _statusMessage = 'Agent disconnected';
          notifyListeners();
          unawaited(_reconnect(epoch));
        },
      );

      await _refreshProviders();
      if (epoch != _epoch) return;

      _connection = AgentConnectionState.ready;
      _statusMessage = _connectedProviders.isEmpty
          ? 'Add an API key in Settings'
          : 'Ready';
      notifyListeners();
    } catch (e) {
      if (epoch != _epoch) return;
      _connection = AgentConnectionState.error;
      _error = e.toString();
      _statusMessage = 'Agent failed to start';
      notifyListeners();
    }
  }

  Future<void> _reconnect(int epoch) async {
    await Future<void>.delayed(const Duration(seconds: 1));
    if (epoch != _epoch) return;
    final path = _boundProjectPath;
    if (path == null) return;
    try {
      final base = _serve.baseUrl;
      if (base == null) {
        await _startForProject(path);
        return;
      }
      await _sse.connect(base);
      await _sseSub?.cancel();
      _sseSub = _sse.events.listen(_onEvent, onError: (_) {});
      if (_connection == AgentConnectionState.error) {
        _connection = AgentConnectionState.ready;
        _statusMessage = 'Ready';
        _error = null;
        notifyListeners();
      }
    } catch (_) {}
  }

  Future<void> refreshProviders() => _refreshProviders();

  Future<void> _refreshProviders() async {
    try {
      if (_client.baseUrl != null) {
        final result = await _client.listProviders();
        _connectedProviders = result.connected;
      } else {
        _connectedProviders =
            (await _authStore.connectedProviderIds()).toList()..sort();
      }
    } catch (_) {
      _connectedProviders =
          (await _authStore.connectedProviderIds()).toList()..sort();
    }
    await _refreshModels();
    notifyListeners();
  }

  Future<void> _refreshModels() async {
    if (_client.baseUrl == null) {
      _availableModels = [];
      return;
    }
    try {
      final models = await _client.listModels();
      final connected = _connectedProviders.toSet();
      _availableModels = [
        for (final m in models)
          if (connected.contains(m.providerId))
            AgentModelOption(
              providerId: m.providerId,
              modelId: m.modelId,
              label: m.label,
            ),
      ];
      await _ensureDefaultModel();
    } catch (_) {
      _availableModels = [];
    }
  }

  Future<void> _ensureDefaultModel() async {
    if (_availableModels.isEmpty) return;

    final currentValid = _defaultModel != null &&
        _availableModels.any((m) => m.value == _defaultModel);
    if (currentValid) return;

    final preferred = pickPreferredDefaultModel(_availableModels);
    final next = preferred?.value ?? _availableModels.first.value;
    await setDefaultModel(next);
  }

  Future<void> saveApiKey(String providerId, String key) async {
    await _authStore.setApiKey(providerId, key);
    if (_client.baseUrl != null) {
      try {
        await _client.setAuthApiKey(providerId, key);
      } catch (_) {
        // File write is source of truth; restart picks it up if PUT fails.
        await _restartServePreservingChat();
      }
    }
    await _refreshProviders();
    if (_connection == AgentConnectionState.ready &&
        _connectedProviders.isNotEmpty) {
      _statusMessage = 'Ready';
      notifyListeners();
    }
  }

  Future<void> removeApiKey(String providerId) async {
    await _authStore.remove(providerId);
    await _restartServePreservingChat();
    await _refreshProviders();
  }

  Future<void> _restartServePreservingChat() async {
    final path = _boundProjectPath;
    if (path == null) return;
    final messages = List<AgentChatMessage>.from(_messages);
    final sessionId = _sessionId;
    final epoch = ++_epoch;
    await _teardown(clearMessages: false, bumpEpoch: false);
    if (epoch != _epoch) return;
    _messages
      ..clear()
      ..addAll(messages);
    _sessionId = sessionId;
    _boundProjectPath = path;
    _connection = AgentConnectionState.starting;
    _statusMessage = 'Reloading agent…';
    notifyListeners();
    try {
      final base = await _serve.start(path);
      if (epoch != _epoch) return;
      _client.attach(base);
      await _sse.connect(base);
      await _sseSub?.cancel();
      _sseSub = _sse.events.listen(_onEvent, onError: (_) {});
      await _refreshProviders();
      _connection = AgentConnectionState.ready;
      _statusMessage = 'Ready';
      notifyListeners();
    } catch (e) {
      _connection = AgentConnectionState.error;
      _error = e.toString();
      _statusMessage = 'Agent failed to reload';
      notifyListeners();
    }
  }

  Future<void> send(String text) async {
    final trimmed = text.trim();
    if (trimmed.isEmpty || !canSend) return;

    _messages.add(
      AgentChatMessage(
        id: 'local_user_${DateTime.now().microsecondsSinceEpoch}',
        role: AgentMessageRole.user,
        parts: [
          AgentTextPart(
            id: 'local_user_text_${DateTime.now().microsecondsSinceEpoch}',
            text: trimmed,
          ),
        ],
      ),
    );
    _connection = AgentConnectionState.busy;
    _statusMessage = 'Working…';
    notifyListeners();

    try {
      _sessionId ??= await _client.createSession(title: 'App Studio');
      String? providerId;
      String? modelId;
      final model = _defaultModel;
      if (model != null && model.contains('/')) {
        final idx = model.indexOf('/');
        providerId = model.substring(0, idx);
        modelId = model.substring(idx + 1);
      }
      await _client.promptAsync(
        sessionId: _sessionId!,
        text: trimmed,
        providerId: providerId,
        modelId: modelId,
        agent: _mode.apiName,
      );
    } catch (e) {
      _messages.add(
        AgentChatMessage(
          id: 'local_err_${DateTime.now().microsecondsSinceEpoch}',
          role: AgentMessageRole.system,
          parts: [
            AgentErrorPart(
              id: 'err_${DateTime.now().microsecondsSinceEpoch}',
              message: e.toString(),
            ),
          ],
        ),
      );
      _connection = AgentConnectionState.ready;
      _statusMessage = 'Ready';
      notifyListeners();
    }
  }

  Future<void> abort() async {
    final id = _sessionId;
    if (id == null) return;
    try {
      await _client.abort(id);
    } catch (_) {}
    _connection = AgentConnectionState.ready;
    _statusMessage = 'Ready';
    notifyListeners();
  }

  Future<void> respondPermission({
    required AgentPermissionPart part,
    required bool allow,
  }) async {
    if (part.resolved) return;
    try {
      await _client.replyPermission(
        sessionId: part.sessionId,
        permissionId: part.permissionId,
        response: allow ? 'allow' : 'deny',
      );
    } catch (_) {}
    part.resolved = true;
    _pendingPermissions.removeWhere((p) => p.id == part.id);
    notifyListeners();
  }

  void _onEvent(Map<String, dynamic> event) {
    final type = event['type']?.toString();
    if (type == null) return;
    final props = event['properties'];
    final properties = props is Map<String, dynamic>
        ? props
        : props is Map
            ? props.map((k, v) => MapEntry(k.toString(), v))
            : <String, dynamic>{};

    switch (type) {
      case 'message.updated':
        _handleMessageUpdated(properties);
      case 'message.part.updated':
        _handlePartUpdated(properties);
      case 'permission.updated':
      case 'permission.asked':
        _handlePermission(properties);
      case 'session.error':
        _handleSessionError(properties);
      case 'session.idle':
      case 'session.status':
        _handleSessionStatus(type, properties);
      default:
        break;
    }
  }

  void _handleMessageUpdated(Map<String, dynamic> properties) {
    final info = properties['info'];
    if (info is! Map) return;
    final map = info.map((k, v) => MapEntry(k.toString(), v));
    final id = map['id']?.toString();
    final role = map['role']?.toString();
    if (id == null || role == null) return;
    if (role != 'user' && role != 'assistant') return;

    final existing = _findMessage(id);
    if (existing != null) {
      notifyListeners();
      return;
    }

    // Prefer replacing optimistic local user message.
    if (role == 'user') {
      final localIdx = _messages.lastIndexWhere(
        (m) => m.role == AgentMessageRole.user && m.id.startsWith('local_user_'),
      );
      if (localIdx >= 0) {
        final local = _messages[localIdx];
        _messages[localIdx] = AgentChatMessage(
          id: id,
          role: AgentMessageRole.user,
          parts: local.parts,
        );
        notifyListeners();
        return;
      }
    }

    _messages.add(
      AgentChatMessage(
        id: id,
        role: role == 'user'
            ? AgentMessageRole.user
            : AgentMessageRole.assistant,
      ),
    );
    if (role == 'assistant') {
      _connection = AgentConnectionState.busy;
      _statusMessage = 'Working…';
    }
    notifyListeners();
  }

  void _handlePartUpdated(Map<String, dynamic> properties) {
    final partRaw = properties['part'];
    if (partRaw is! Map) return;
    final part = partRaw.map((k, v) => MapEntry(k.toString(), v));
    final messageId = part['messageID']?.toString();
    final partId = part['id']?.toString();
    final partType = part['type']?.toString();
    if (messageId == null || partId == null || partType == null) return;

    var message = _findMessage(messageId);
    if (message == null) {
      message = AgentChatMessage(
        id: messageId,
        role: AgentMessageRole.assistant,
      );
      _messages.add(message);
    }

    final delta = properties['delta']?.toString();

    switch (partType) {
      case 'text':
        final text = part['text']?.toString() ?? '';
        final existing = _findTextPart(message, partId);
        if (existing != null) {
          if (delta != null && delta.isNotEmpty) {
            existing.text += delta;
          } else if (text.isNotEmpty) {
            existing.text = text;
          }
        } else {
          final content = text.isNotEmpty ? text : (delta ?? '');
          // Adopt optimistic local user text instead of appending a duplicate.
          final localText = message.parts.whereType<AgentTextPart>().where(
                (p) => p.id.startsWith('local_'),
              );
          final adopt = localText.isNotEmpty ? localText.first : null;
          if (adopt != null) {
            final idx = message.parts.indexOf(adopt);
            message.parts[idx] = AgentTextPart(
              id: partId,
              text: content.isNotEmpty ? content : adopt.text,
            );
          } else {
            message.parts.add(AgentTextPart(id: partId, text: content));
          }
        }
      case 'reasoning':
        // Fold reasoning into a muted text part prefixed.
        final text = part['text']?.toString() ?? '';
        final existing = _findTextPart(message, partId);
        final content = text.isNotEmpty ? text : (delta ?? '');
        if (content.isEmpty) break;
        if (existing != null) {
          if (delta != null && delta.isNotEmpty) {
            existing.text += delta;
          } else {
            existing.text = content;
          }
        } else {
          message.parts.add(AgentTextPart(id: partId, text: content));
        }
      case 'tool':
        final tool = part['tool']?.toString() ?? 'tool';
        final stateRaw = part['state'];
        final state = stateRaw is Map
            ? stateRaw.map((k, v) => MapEntry(k.toString(), v))
            : <String, dynamic>{};
        final statusStr = state['status']?.toString() ?? 'running';
        final status = switch (statusStr) {
          'pending' => AgentToolStatus.pending,
          'running' => AgentToolStatus.running,
          'completed' => AgentToolStatus.completed,
          'error' => AgentToolStatus.error,
          _ => AgentToolStatus.running,
        };
        final title = state['title']?.toString();
        final output = state['output']?.toString();
        final error = state['error']?.toString();
        String? input;
        final inputRaw = state['input'];
        if (inputRaw != null) {
          input = inputRaw is String ? inputRaw : jsonEncode(inputRaw);
        }

        final existing = _findToolPart(message, partId);
        if (existing != null) {
          existing.status = status;
          existing.title = title ?? existing.title;
          existing.input = input ?? existing.input;
          existing.output = output ?? existing.output;
          existing.error = error ?? existing.error;
        } else {
          message.parts.add(
            AgentToolPart(
              id: partId,
              tool: tool,
              status: status,
              title: title,
              input: input,
              output: output,
              error: error,
            ),
          );
        }
        _connection = AgentConnectionState.busy;
        _statusMessage = 'Working…';
      default:
        break;
    }
    notifyListeners();
  }

  AgentTextPart? _findTextPart(AgentChatMessage message, String partId) {
    for (final p in message.parts) {
      if (p is AgentTextPart && p.id == partId) return p;
    }
    return null;
  }

  AgentToolPart? _findToolPart(AgentChatMessage message, String partId) {
    for (final p in message.parts) {
      if (p is AgentToolPart && p.id == partId) return p;
    }
    return null;
  }

  void _handlePermission(Map<String, dynamic> properties) {
    // Shapes vary; try common fields.
    final id = (properties['id'] ??
            properties['permissionID'] ??
            properties['permissionId'])
        ?.toString();
    final sessionId =
        (properties['sessionID'] ?? properties['sessionId'] ?? _sessionId)
            ?.toString();
    if (id == null || sessionId == null) return;

    final title = (properties['permission'] ??
            properties['tool'] ??
            properties['title'] ??
            'Permission required')
        .toString();

    final part = AgentPermissionPart(
      id: 'perm_$id',
      permissionId: id,
      sessionId: sessionId,
      title: title,
      metadata: properties,
    );
    if (_pendingPermissions.any((p) => p.permissionId == id)) return;
    _pendingPermissions.add(part);

    // Also attach to latest assistant message for inline display.
    AgentChatMessage? assistant;
    for (var i = _messages.length - 1; i >= 0; i--) {
      if (_messages[i].role == AgentMessageRole.assistant) {
        assistant = _messages[i];
        break;
      }
    }
    if (assistant != null) {
      assistant.parts.add(part);
    } else {
      _messages.add(
        AgentChatMessage(
          id: 'perm_msg_$id',
          role: AgentMessageRole.system,
          parts: [part],
        ),
      );
    }
    notifyListeners();
  }

  void _handleSessionError(Map<String, dynamic> properties) {
    final err = properties['error'];
    String message = 'Session error';
    if (err is Map) {
      message = (err['data'] is Map
              ? (err['data'] as Map)['message']
              : err['message'])
          ?.toString() ??
          err['name']?.toString() ??
          message;
    } else if (err != null) {
      message = err.toString();
    }
    _messages.add(
      AgentChatMessage(
        id: 'sess_err_${DateTime.now().microsecondsSinceEpoch}',
        role: AgentMessageRole.system,
        parts: [
          AgentErrorPart(
            id: 'err_${DateTime.now().microsecondsSinceEpoch}',
            message: message,
          ),
        ],
      ),
    );
    _connection = AgentConnectionState.ready;
    _statusMessage = 'Ready';
    notifyListeners();
  }

  void _handleSessionStatus(String type, Map<String, dynamic> properties) {
    if (type == 'session.idle') {
      if (_connection == AgentConnectionState.busy) {
        _connection = AgentConnectionState.ready;
        _statusMessage = 'Ready';
        notifyListeners();
        _notifyAgentFinished();
      }
      return;
    }
    // session.status may include per-session map
    final status = properties['status'] ?? properties[_sessionId ?? ''];
    final statusStr = status is Map
        ? status['type']?.toString() ?? status.toString()
        : status?.toString();
    if (statusStr == 'idle' || statusStr == 'completed') {
      if (_connection == AgentConnectionState.busy) {
        _connection = AgentConnectionState.ready;
        _statusMessage = 'Ready';
        notifyListeners();
        _notifyAgentFinished();
      }
    } else if (statusStr == 'busy' || statusStr == 'running') {
      _connection = AgentConnectionState.busy;
      _statusMessage = 'Working…';
      notifyListeners();
    }
  }

  void _notifyAgentFinished() {
    final summary = _latestAssistantSummary();
    unawaited(StudioNotifications.agentTaskCompleted(summary: summary));
  }

  /// Short plain-text snippet from the latest assistant message, if any.
  String? _latestAssistantSummary() {
    for (var i = _messages.length - 1; i >= 0; i--) {
      final msg = _messages[i];
      if (msg.role != AgentMessageRole.assistant) continue;
      final buf = StringBuffer();
      for (final part in msg.parts) {
        if (part is AgentTextPart) {
          final t = part.text.trim();
          if (t.isNotEmpty) {
            if (buf.isNotEmpty) buf.write(' ');
            buf.write(t);
          }
        }
      }
      final text = buf.toString().replaceAll(RegExp(r'\s+'), ' ').trim();
      if (text.isEmpty) return null;
      if (text.length <= 120) return text;
      return '${text.substring(0, 117)}…';
    }
    return null;
  }

  AgentChatMessage? _findMessage(String id) {
    for (final m in _messages) {
      if (m.id == id) return m;
    }
    return null;
  }

  Future<void> _teardown({
    required bool clearMessages,
    bool bumpEpoch = true,
  }) async {
    if (bumpEpoch) _epoch++;
    await _sseSub?.cancel();
    _sseSub = null;
    await _sse.disconnect();
    _client.detach();
    await _serve.stop();
    _sessionId = null;
    _boundProjectPath = null;
    _pendingPermissions.clear();
    _availableModels = [];
    if (clearMessages) _messages.clear();
    _connection = AgentConnectionState.idle;
    _statusMessage = null;
    _error = null;
    notifyListeners();
  }

  @override
  void dispose() {
    session.removeListener(_onSessionOrProcessChanged);
    process.removeListener(_onSessionOrProcessChanged);
    unawaited(_teardown(clearMessages: true));
    unawaited(_sse.dispose());
    _client.close();
    super.dispose();
  }
}
