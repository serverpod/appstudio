enum AgentMessageRole { user, assistant, system }

enum AgentPartKind { text, tool, permission, error }

enum AgentToolStatus { pending, running, completed, error }

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

class AgentToolPart extends AgentPart {
  AgentToolPart({
    required super.id,
    required this.tool,
    required this.status,
    this.title,
    this.input,
    this.output,
    this.error,
  });

  final String tool;
  AgentToolStatus status;
  String? title;
  String? input;
  String? output;
  String? error;
}

class AgentPermissionPart extends AgentPart {
  AgentPermissionPart({
    required super.id,
    required this.permissionId,
    required this.sessionId,
    required this.title,
    required this.metadata,
    this.resolved = false,
  });

  final String permissionId;
  final String sessionId;
  final String title;
  final Map<String, dynamic> metadata;
  bool resolved;
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
