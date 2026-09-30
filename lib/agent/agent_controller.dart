import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

import '../platform/studio_notifications.dart';
import '../process/serverpod_process.dart';
import '../session/project_session.dart';
import '../toolchain/toolchain_controller.dart';
import 'agent_transcript.dart';
import '../feature_flags.dart';
import 'opencode_auth_store.dart';
import 'opencode_client.dart';
import 'opencode_serve.dart';
import 'opencode_sse.dart';
import '../ui/settings/providers_view.dart';

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

/// Human-readable label for an OpenCode permission action.
String permissionTitle(String action) {
  final key = action.trim().toLowerCase();
  return switch (key) {
    'bash' => 'Run a terminal command',
    'edit' || 'write' || 'patch' => 'Change files',
    'read' => 'Read a file outside the project',
    'list' || 'glob' || 'grep' => 'Look outside the project',
    'webfetch' || 'fetch' => 'Fetch a web page',
    '' => 'Permission required',
    _ => 'Allow ${action.trim()}',
  };
}

/// Owns OpenCode serve lifecycle, SSE transcript, and chat actions.
class AgentController extends ChangeNotifier implements ProvidersView {
  AgentController({
    required this.toolchains,
    required this.session,
    required this.process,
    OpenCodeAuthStore? authStore,
  })  : _authStore = authStore ?? OpenCodeAuthStore(),
        _serve = OpenCodeServe(toolchains: toolchains),
        _client = OpenCodeClient(),
        _sse = OpenCodeSse() {
    // Switched off, the controller is inert: it is still constructed, still
    // handed to everything that expects one, and still stopped by the session
    // teardown — it simply never listens for a project and so never spawns
    // `opencode serve`. Nothing shows what it would report anyway.
    if (!kOpenCodeAgentEnabled) return;
    session.addListener(_onSessionOrProcessChanged);
    process.addListener(_onSessionOrProcessChanged);
    unawaited(_loadPrefs());
    _onSessionOrProcessChanged();
  }

  final ToolchainController toolchains;
  final ProjectSession session;
  final ServerpodProcessController process;
  final OpenCodeAuthStore _authStore;
  final OpenCodeServe _serve;
  final OpenCodeClient _client;
  final OpenCodeSse _sse;

  static const _prefsModelKey = 'agent.default_model';
  static const _prefsModeKey = 'agent.chat_mode';

  /// Working directory for a serve started by [startForSettings].
  static const _kSettingsScratchDirName = 'agent-scratch';

  /// True while the running serve exists only for Settings, with no project
  /// behind it. Opening a project supersedes it and clears this.
  bool _startedForSettings = false;

  AgentConnectionState _connection = AgentConnectionState.idle;
  String? _statusMessage;
  String? _error;
  String? _sessionId;
  String? _boundProjectPath;
  final List<AgentChatMessage> _messages = [];
  final List<AgentPermissionPart> _pendingPermissions = [];
  final List<AgentQuestionPart> _pendingQuestions = [];

  /// Tool calls replaced by a question card, so the raw row stays hidden even
  /// if a later `message.part.updated` recreates it.
  final Set<String> _hiddenToolCalls = {};
  List<String> _connectedProviders = [];
  List<AgentModelOption> _availableModels = [];
  String? _defaultModel; // provider/model
  AgentChatMode _mode = AgentChatMode.agent;
  StreamSubscription<Map<String, dynamic>>? _sseSub;
  int _epoch = 0;
  bool _disposed = false;
  VoidCallback? _onOpenSettings;

  AgentConnectionState get connection => _connection;
  String? get statusMessage => _statusMessage;
  String? get error => _error;
  List<AgentChatMessage> get messages => List.unmodifiable(_messages);
  List<AgentPermissionPart> get pendingPermissions =>
      List.unmodifiable(_pendingPermissions);
  List<AgentQuestionPart> get pendingQuestions =>
      List.unmodifiable(_pendingQuestions);
  /// True once `opencode serve` has answered, so the provider and model lists
  /// mean something. Not the same as [canSend], which also waits for Serverpod.
  @override
  bool get agentReady =>
      _connection == AgentConnectionState.ready ||
      _connection == AgentConnectionState.busy;

  @override
  List<String> get connectedProviders =>
      List.unmodifiable(_connectedProviders);
  List<AgentModelOption> get availableModels =>
      List.unmodifiable(_availableModels);
  @override
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

  // --- ProvidersView -------------------------------------------------------
  //
  // The Providers pane talks to this interface instead of to the controller,
  // so it never imports the OpenCode auth store and stays previewable.

  @override
  Future<List<ProviderModel>> listModels() async {
    if (_client.baseUrl == null) return const [];
    final models = await _client.listModels();
    return [
      for (final m in models)
        ProviderModel(
          providerId: m.providerId,
          modelId: m.modelId,
          label: m.label,
        ),
    ];
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

  @override
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

    // A real project supersedes any scratch serve Settings started, and must
    // not be torn down when Settings closes.
    _startedForSettings = false;

    // Deliberately *not* gated on `process.previewReady`. `opencode serve` is
    // an independent process that only needs the project directory, and the
    // Serverpod build it used to wait for takes minutes on a cold project —
    // long enough that Settings could not show which providers hold a key.
    //
    // This does not make the agent usable early: [canSend] still requires
    // `previewReady`, and `AgentPane` still shows its "Serverpod is starting"
    // gate, so the main interface is unchanged.
    if (path == _boundProjectPath &&
        (_connection == AgentConnectionState.ready ||
            _connection == AgentConnectionState.busy ||
            _connection == AgentConnectionState.starting)) {
      return;
    }
    unawaited(_startForProject(path));
  }

  /// Brings the agent up with no project open, so Settings can list providers
  /// and models before anything has been opened.
  ///
  /// `opencode serve` is given a working directory, and with no project there
  /// is nothing meaningful to hand it, so it gets a scratch directory under
  /// Application Support — a real path it can write its own state into without
  /// dropping `.opencode` clutter somewhere the user cares about. The keys it
  /// reports come from the OpenCode config in the user's home either way, so
  /// the directory's contents do not matter.
  ///
  /// Does nothing once a project is open: that agent is the real one.
  Future<void> startForSettings() async {
    // Settings has no Providers tab to fill in when the agent is off, so there
    // is nothing for a scratch serve to answer.
    if (!kOpenCodeAgentEnabled) return;
    if (session.hasProject ||
        _serve.isRunning ||
        _connection == AgentConnectionState.starting) {
      return;
    }
    final dir = Directory(
      p.join(toolchains.paths.appSupportRoot, _kSettingsScratchDirName),
    );
    // Claimed before the first await. Set after, a Settings dialog closed while
    // the directory was still being created would find the flag false, decline
    // to stop, and leave a scratch serve running that nothing owns.
    _startedForSettings = true;
    try {
      await dir.create(recursive: true);
    } catch (e) {
      _startedForSettings = false;
      _error = 'Could not prepare a workspace for the agent: $e';
      _connection = AgentConnectionState.error;
      notifyListeners();
      return;
    }
    // Settings closed while the directory was being created, so
    // [stopIfStartedForSettings] has already released the claim. Starting now
    // would spawn a serve with nobody left to stop it.
    if (!_startedForSettings) return;
    await _startForProject(dir.path);
  }

  /// Stops the agent and waits for `opencode serve` to actually be gone.
  ///
  /// [dispose] cannot await — `ChangeNotifier.dispose()` is synchronous — so it
  /// can only fire the teardown and return, which is how every quit left an
  /// orphaned `opencode serve` reparented to launchd. The session teardown calls
  /// this instead.
  Future<void> stop() => _teardown(clearMessages: true);

  /// Stops a serve that [startForSettings] started. A project's own agent is
  /// left running — closing Settings must not tear down a live session.
  Future<void> stopIfStartedForSettings() async {
    if (!_startedForSettings) return;
    _startedForSettings = false;
    await _teardown(clearMessages: true);
  }

  Future<void> _startForProject(String projectPath) async {
    final epoch = ++_epoch;
    // Claimed *before* the teardown, not after. `_teardown` nulls
    // `_boundProjectPath` and sets the connection back to idle, and `process`
    // notifies on every poll tick — so a tick landing inside the teardown used
    // to pass `_onSessionOrProcessChanged`'s idempotency guard and start a
    // second serve concurrently with this one.
    _boundProjectPath = projectPath;
    _connection = AgentConnectionState.starting;
    _statusMessage = 'Starting agent…';
    _error = null;
    notifyListeners();

    await _teardown(clearMessages: true, bumpEpoch: false, keepClaim: true);
    if (epoch != _epoch) return;

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

  @override
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

  @override
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
    // Claimed before the teardown for the same reason as [_startForProject]: a
    // `process` tick landing while the serve is being stopped would otherwise
    // see an idle, unclaimed controller and start a second one.
    _connection = AgentConnectionState.starting;
    _statusMessage = 'Reloading agent…';
    notifyListeners();

    await _teardown(clearMessages: false, bumpEpoch: false, keepClaim: true);
    if (epoch != _epoch) return;
    _messages
      ..clear()
      ..addAll(messages);
    _sessionId = sessionId;
    _boundProjectPath = path;
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
    required AgentPermissionReply reply,
  }) async {
    if (part.resolved || part.submitting) return;
    part.submitting = true;
    part.error = null;
    notifyListeners();
    try {
      await _client.replyPermission(
        permissionId: part.permissionId,
        reply: reply.wire,
      );
    } catch (e) {
      // Keep the card up: the agent is still blocked waiting for an answer.
      part.submitting = false;
      part.error = 'Could not send the response: $e';
      notifyListeners();
      return;
    }
    part.reply = reply;
    _resolvePermission(part.permissionId, reply);
  }

  Future<void> answerQuestion({
    required AgentQuestionPart part,
    required List<List<String>> answers,
  }) async {
    if (part.resolved || part.submitting) return;
    part.submitting = true;
    part.error = null;
    notifyListeners();
    try {
      await _client.replyQuestion(
        requestId: part.requestId,
        answers: answers,
      );
    } catch (e) {
      part.submitting = false;
      part.error = 'Could not send the answer: $e';
      notifyListeners();
      return;
    }
    part.answers = answers;
    _resolveQuestion(part.requestId, rejected: false);
  }

  Future<void> rejectQuestion(AgentQuestionPart part) async {
    if (part.resolved || part.submitting) return;
    part.submitting = true;
    part.error = null;
    notifyListeners();
    try {
      await _client.rejectQuestion(part.requestId);
    } catch (e) {
      part.submitting = false;
      part.error = 'Could not skip the question: $e';
      notifyListeners();
      return;
    }
    _resolveQuestion(part.requestId, rejected: true);
  }

  void _resolvePermission(String permissionId, AgentPermissionReply? reply) {
    for (final message in _messages) {
      for (final part in message.parts) {
        if (part is AgentPermissionPart && part.permissionId == permissionId) {
          part.submitting = false;
          part.resolved = true;
          part.reply ??= reply;
        }
      }
    }
    _pendingPermissions.removeWhere((p) => p.permissionId == permissionId);
    notifyListeners();
  }

  void _resolveQuestion(String requestId, {required bool rejected}) {
    for (final message in _messages) {
      for (final part in message.parts) {
        if (part is AgentQuestionPart && part.requestId == requestId) {
          part.submitting = false;
          part.resolved = true;
          part.rejected = rejected;
        }
      }
    }
    _pendingQuestions.removeWhere((q) => q.requestId == requestId);
    notifyListeners();
  }

  @visibleForTesting
  void handleEvent(Map<String, dynamic> event) => _onEvent(event);

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
      case 'message.part.delta':
        _handlePartDelta(properties);
      case 'permission.updated':
      case 'permission.asked':
      case 'permission.v2.asked':
        _handlePermission(properties);
      case 'permission.replied':
      case 'permission.v2.replied':
        _handlePermissionReplied(properties);
      case 'question.asked':
      case 'question.v2.asked':
        _handleQuestion(properties);
      case 'question.replied':
      case 'question.v2.replied':
        _handleQuestionResolved(properties, rejected: false);
      case 'question.rejected':
      case 'question.v2.rejected':
        _handleQuestionResolved(properties, rejected: true);
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
        final text = part['text']?.toString() ?? '';
        final existing = _findReasoningPart(message, partId);
        final content = text.isNotEmpty ? text : (delta ?? '');
        if (content.isEmpty) break;
        if (existing != null) {
          if (delta != null && delta.isNotEmpty) {
            existing.text += delta;
          } else {
            existing.text = content;
          }
        } else {
          message.parts.add(AgentReasoningPart(id: partId, text: content));
        }
      case 'tool':
        final tool = part['tool']?.toString() ?? 'tool';
        final callId = part['callID']?.toString();
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
              callId: callId,
              status: status,
              title: title,
              input: input,
              output: output,
              error: error,
              // A question/permission card may already stand in for this call.
              hidden: callId != null && _hiddenToolCalls.contains(callId),
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

  /// Streaming chunks arrive separately from `message.part.updated`, which
  /// only carries whole snapshots.
  void _handlePartDelta(Map<String, dynamic> properties) {
    final messageId = properties['messageID']?.toString();
    final partId = properties['partID']?.toString();
    final delta = properties['delta']?.toString();
    final field = properties['field']?.toString();
    if (messageId == null || partId == null || delta == null) return;
    if (delta.isEmpty) return;
    if (field != null && field != 'text') return;

    var message = _findMessage(messageId);
    if (message == null) {
      message = AgentChatMessage(
        id: messageId,
        role: AgentMessageRole.assistant,
      );
      _messages.add(message);
    }

    final text = _findTextPart(message, partId);
    if (text != null) {
      text.text += delta;
      notifyListeners();
      return;
    }
    final reasoning = _findReasoningPart(message, partId);
    if (reasoning != null) {
      reasoning.text += delta;
      notifyListeners();
      return;
    }
    message.parts.add(AgentTextPart(id: partId, text: delta));
    notifyListeners();
  }

  AgentTextPart? _findTextPart(AgentChatMessage message, String partId) {
    for (final p in message.parts) {
      if (p is AgentTextPart && p.id == partId) return p;
    }
    return null;
  }

  AgentReasoningPart? _findReasoningPart(
    AgentChatMessage message,
    String partId,
  ) {
    for (final p in message.parts) {
      if (p is AgentReasoningPart && p.id == partId) return p;
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
    final id = (properties['id'] ??
            properties['permissionID'] ??
            properties['permissionId'])
        ?.toString();
    final sessionId =
        (properties['sessionID'] ?? properties['sessionId'] ?? _sessionId)
            ?.toString();
    if (id == null || sessionId == null) return;
    if (_pendingPermissions.any((p) => p.permissionId == id)) return;

    // `permission` on v1 events, `action` on v2.
    final action =
        (properties['permission'] ?? properties['action'] ?? '').toString();
    // `patterns` on v1 events, `resources` on v2.
    final details = _stringList(properties['patterns']) +
        _stringList(properties['resources']);

    final part = AgentPermissionPart(
      id: 'perm_$id',
      permissionId: id,
      sessionId: sessionId,
      title: permissionTitle(action),
      details: details,
      canRemember: _stringList(properties['always']).isNotEmpty ||
          _stringList(properties['save']).isNotEmpty,
      metadata: properties,
    );
    _pendingPermissions.add(part);
    _attachRequestPart(
      part: part,
      tool: properties['tool'],
      fallbackMessageId: 'perm_msg_$id',
      hideToolRow: false,
    );
    notifyListeners();
  }

  void _handlePermissionReplied(Map<String, dynamic> properties) {
    final id = (properties['requestID'] ??
            properties['permissionID'] ??
            properties['id'])
        ?.toString();
    if (id == null) return;
    final reply = switch (properties['reply']?.toString()) {
      'once' => AgentPermissionReply.once,
      'always' => AgentPermissionReply.always,
      'reject' => AgentPermissionReply.reject,
      _ => null,
    };
    _resolvePermission(id, reply);
  }

  void _handleQuestion(Map<String, dynamic> properties) {
    final id = (properties['id'] ?? properties['requestID'])?.toString();
    final sessionId =
        (properties['sessionID'] ?? properties['sessionId'] ?? _sessionId)
            ?.toString();
    if (id == null || sessionId == null) return;
    if (_pendingQuestions.any((q) => q.requestId == id)) return;

    final raw = properties['questions'];
    if (raw is! List || raw.isEmpty) return;
    final questions = <AgentQuestion>[];
    for (final entry in raw) {
      if (entry is! Map) continue;
      final map = entry.map((k, v) => MapEntry(k.toString(), v));
      final options = <AgentQuestionOption>[];
      final optionsRaw = map['options'];
      if (optionsRaw is List) {
        for (final o in optionsRaw) {
          if (o is! Map) continue;
          final om = o.map((k, v) => MapEntry(k.toString(), v));
          final label = om['label']?.toString();
          if (label == null || label.isEmpty) continue;
          options.add(
            AgentQuestionOption(
              label: label,
              description: om['description']?.toString() ?? '',
            ),
          );
        }
      }
      questions.add(
        AgentQuestion(
          header: map['header']?.toString() ?? '',
          question: map['question']?.toString() ?? '',
          options: options,
          multiple: map['multiple'] == true,
          custom: map['custom'] == true,
        ),
      );
    }
    if (questions.isEmpty) return;

    final part = AgentQuestionPart(
      id: 'ques_$id',
      requestId: id,
      sessionId: sessionId,
      questions: questions,
    );
    _pendingQuestions.add(part);
    // The card carries everything the raw `question` tool row would show.
    _attachRequestPart(
      part: part,
      tool: properties['tool'],
      fallbackMessageId: 'ques_msg_$id',
      hideToolRow: true,
    );
    notifyListeners();
  }

  void _handleQuestionResolved(
    Map<String, dynamic> properties, {
    required bool rejected,
  }) {
    final id = (properties['requestID'] ?? properties['id'])?.toString();
    if (id == null) return;
    _resolveQuestion(id, rejected: rejected);
  }

  /// Places a permission/question card next to the tool call that triggered
  /// it, falling back to the latest assistant message.
  void _attachRequestPart({
    required AgentPart part,
    required Object? tool,
    required String fallbackMessageId,
    required bool hideToolRow,
  }) {
    String? messageId;
    String? callId;
    if (tool is Map) {
      messageId = tool['messageID']?.toString();
      callId = tool['callID']?.toString();
    }
    if (hideToolRow && callId != null) _hiddenToolCalls.add(callId);

    var message = messageId == null ? null : _findMessage(messageId);
    if (message != null && callId != null) {
      final idx = message.parts.indexWhere(
        (p) => p is AgentToolPart && p.callId == callId,
      );
      if (idx >= 0) {
        if (hideToolRow) (message.parts[idx] as AgentToolPart).hidden = true;
        message.parts.insert(idx + 1, part);
        return;
      }
    }

    if (message == null) {
      for (var i = _messages.length - 1; i >= 0; i--) {
        if (_messages[i].role == AgentMessageRole.assistant) {
          message = _messages[i];
          break;
        }
      }
    }
    if (message != null) {
      message.parts.add(part);
      return;
    }
    _messages.add(
      AgentChatMessage(
        id: fallbackMessageId,
        role: AgentMessageRole.system,
        parts: [part],
      ),
    );
  }

  static List<String> _stringList(Object? value) {
    if (value is! List) return const [];
    return [
      for (final v in value)
        if (v != null && v.toString().isNotEmpty) v.toString(),
    ];
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
    // Blocked on the user, not finished.
    if (_pendingPermissions.isNotEmpty || _pendingQuestions.isNotEmpty) return;
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
    bool keepClaim = false,
  }) async {
    if (bumpEpoch) _epoch++;
    await _sseSub?.cancel();
    _sseSub = null;
    await _sse.disconnect();
    _client.detach();
    await _serve.stop();
    _sessionId = null;
    // A start in progress has already claimed the project and the `starting`
    // state; clearing them here is what let a concurrent start slip through.
    if (!keepClaim) _boundProjectPath = null;
    _pendingPermissions.clear();
    _pendingQuestions.clear();
    _hiddenToolCalls.clear();
    _availableModels = [];
    if (clearMessages) _messages.clear();
    if (!keepClaim) {
      _connection = AgentConnectionState.idle;
      _statusMessage = null;
      _error = null;
    }
    notifyListeners();
  }

  @override
  void notifyListeners() {
    // Teardown runs async and can outlive dispose().
    if (_disposed) return;
    super.notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    session.removeListener(_onSessionOrProcessChanged);
    process.removeListener(_onSessionOrProcessChanged);
    unawaited(_teardown(clearMessages: true));
    unawaited(_sse.dispose());
    _client.close();
    super.dispose();
  }
}
