enum AgentMessageRole { user, assistant, system }

enum AgentPartKind { text, reasoning, tool, permission, question, error }

enum AgentToolStatus { pending, running, completed, error }

/// Wire values accepted by OpenCode's permission reply endpoint.
enum AgentPermissionReply {
  once,
  always,
  reject;

  String get wire => name;
}

class AgentChatMessage {
  AgentChatMessage({
    required this.id,
    required this.role,
    List<AgentPart>? parts,
  }) : parts = parts ?? [];

  final String id;
  final AgentMessageRole role;
  final List<AgentPart> parts;

  String get text {
    final buf = StringBuffer();
    for (final part in parts) {
      if (part is AgentTextPart) buf.write(part.text);
    }
    return buf.toString();
  }
}

sealed class AgentPart {
  AgentPart({required this.id});

  final String id;
}

class AgentTextPart extends AgentPart {
  AgentTextPart({required super.id, required this.text});

  String text;
}

/// Model reasoning; rendered collapsed so it never reads as the answer.
class AgentReasoningPart extends AgentPart {
  AgentReasoningPart({required super.id, required this.text});

  String text;
}

class AgentToolPart extends AgentPart {
  AgentToolPart({
    required super.id,
    required this.tool,
    required this.status,
    this.callId,
    this.title,
    this.input,
    this.output,
    this.error,
    this.hidden = false,
  });

  final String tool;
  final String? callId;
  AgentToolStatus status;
  String? title;
  String? input;
  String? output;
  String? error;

  /// Set when a richer card (question/permission) replaces this row.
  bool hidden;
}

class AgentPermissionPart extends AgentPart {
  AgentPermissionPart({
    required super.id,
    required this.permissionId,
    required this.sessionId,
    required this.title,
    required this.details,
    required this.metadata,
    this.canRemember = false,
    this.resolved = false,
  });

  final String permissionId;
  final String sessionId;
  final String title;

  /// Patterns/resources the request applies to, shown under the title.
  final List<String> details;
  final Map<String, dynamic> metadata;

  /// Whether the server offered an "always allow" rule for this request.
  final bool canRemember;
  bool resolved;
  bool submitting = false;
  AgentPermissionReply? reply;
  String? error;
}

class AgentQuestionOption {
  const AgentQuestionOption({required this.label, required this.description});

  final String label;
  final String description;
}

class AgentQuestion {
  const AgentQuestion({
    required this.header,
    required this.question,
    required this.options,
    this.multiple = false,
    this.custom = false,
  });

  final String header;
  final String question;
  final List<AgentQuestionOption> options;
  final bool multiple;
  final bool custom;
}

class AgentQuestionPart extends AgentPart {
  AgentQuestionPart({
    required super.id,
    required this.requestId,
    required this.sessionId,
    required this.questions,
  });

  final String requestId;
  final String sessionId;
  final List<AgentQuestion> questions;

  bool resolved = false;
  bool rejected = false;
  bool submitting = false;
  String? error;

  /// Selected labels per question, in question order.
  List<List<String>>? answers;
}

class AgentErrorPart extends AgentPart {
  AgentErrorPart({required super.id, required this.message});

  final String message;
}

/// Curated providers shown in Settings.
class CuratedProvider {
  const CuratedProvider({required this.id, required this.label});

  final String id;
  final String label;
}

const curatedProviders = <CuratedProvider>[
  CuratedProvider(id: 'anthropic', label: 'Anthropic'),
  CuratedProvider(id: 'openai', label: 'OpenAI'),
  CuratedProvider(id: 'google', label: 'Google'),
  CuratedProvider(id: 'openrouter', label: 'OpenRouter'),
  CuratedProvider(id: 'opencode', label: 'OpenCode Zen'),
  CuratedProvider(id: 'groq', label: 'Groq'),
  CuratedProvider(id: 'mistral', label: 'Mistral'),
  CuratedProvider(id: 'xai', label: 'xAI'),
  CuratedProvider(id: 'deepseek', label: 'DeepSeek'),
  CuratedProvider(id: 'moonshotai', label: 'Moonshot (Kimi)'),
  CuratedProvider(id: 'moonshotai-cn', label: 'Moonshot CN'),
  CuratedProvider(id: 'minimax', label: 'MiniMax'),
  CuratedProvider(id: 'minimax-cn', label: 'MiniMax CN'),
  CuratedProvider(id: 'zai', label: 'Z.AI (GLM)'),
  CuratedProvider(id: 'zhipuai', label: 'Zhipu AI'),
  CuratedProvider(id: 'alibaba', label: 'Alibaba (Qwen)'),
  CuratedProvider(id: 'alibaba-cn', label: 'Alibaba CN (Qwen)'),
];
