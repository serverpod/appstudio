import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

import '../../agent/agent_controller.dart';
import '../../agent/agent_transcript.dart';
import '../../process/serverpod_process.dart';
import '../../theme/app_colors.dart';
import '../../theme/app_theme.dart';

class AgentPane extends StatefulWidget {
  const AgentPane({
    super.key,
    required this.controller,
    required this.process,
  });

  final AgentController controller;
  final ServerpodProcessController process;

  @override
  State<AgentPane> createState() => _AgentPaneState();
}

class _AgentPaneState extends State<AgentPane> {
  final _scrollController = ScrollController();
  final _inputController = TextEditingController();
  final _inputFocus = FocusNode();
  bool _stickToBottom = true;

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_onController);
    _scrollController.addListener(_onScroll);
  }

  @override
  void didUpdateWidget(covariant AgentPane oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller.removeListener(_onController);
      widget.controller.addListener(_onController);
    }
  }

  @override
  void dispose() {
    widget.controller.removeListener(_onController);
    _scrollController.removeListener(_onScroll);
    _scrollController.dispose();
    _inputController.dispose();
    _inputFocus.dispose();
    super.dispose();
  }

  void _onScroll() {
    if (!_scrollController.hasClients) return;
    final pos = _scrollController.position;
    _stickToBottom = pos.pixels >= pos.maxScrollExtent - 48;
  }

  void _onController() {
    setState(() {});
    if (_stickToBottom) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!_scrollController.hasClients) return;
        _scrollController.jumpTo(_scrollController.position.maxScrollExtent);
      });
    }
  }

  void _send() {
    final text = _inputController.text;
    if (text.trim().isEmpty) return;
    widget.controller.send(text);
    _inputController.clear();
    _stickToBottom = true;
  }

  @override
  Widget build(BuildContext context) {
    final theme = ShadTheme.of(context);
    final scheme = theme.colorScheme;
    final c = widget.controller;
    final serverUp = widget.process.previewReady;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(
          child: _buildBody(context, scheme, theme, c, widget.process),
        ),
        if (serverUp)
          DecoratedBox(
            decoration: BoxDecoration(
              color: scheme.background,
              border: Border(top: paneBorderSide(scheme.border)),
            ),
            child: _Composer(
              controller: _inputController,
              focusNode: _inputFocus,
              enabled: c.canSend || c.isBusy,
              isBusy: c.isBusy,
              onSend: c.canSend ? _send : null,
              onStop: c.isBusy ? () => c.abort() : null,
            ),
          ),
      ],
    );
  }

  Widget _buildBody(
    BuildContext context,
    ShadColorScheme scheme,
    ShadThemeData theme,
    AgentController c,
    ServerpodProcessController process,
  ) {
    if (!c.projectSession.hasProject) {
      return _EmptyHint(
        icon: LucideIcons.folderOpen,
        title: 'Open a project',
        subtitle: 'The agent works inside the currently open Serverpod project.',
      );
    }

    if (!process.previewReady) {
      final starting = switch (process.state) {
        ProcessState.starting ||
        ProcessState.stopping ||
        ProcessState.running =>
          true,
        ProcessState.idle => false,
      };
      return _GateMessage(
        text: starting
            ? 'Serverpod is starting'
            : 'Serverpod is not running',
      );
    }

    if (c.connection == AgentConnectionState.error) {
      return _EmptyHint(
        icon: LucideIcons.circleAlert,
        title: 'Agent unavailable',
        subtitle: c.error ?? c.statusMessage ?? 'Something went wrong.',
      );
    }

    if (!c.hasProviders && c.messages.isEmpty) {
      return _AgentIdleArt(caption: _agentCaption(c));
    }

    if (c.messages.isEmpty) {
      return _AgentIdleArt(caption: _agentCaption(c));
    }

    return ListView.builder(
      controller: _scrollController,
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 16),
      itemCount: c.messages.length + c.pendingPermissions.length,
      itemBuilder: (context, index) {
        if (index < c.messages.length) {
          return _MessageBubble(
            message: c.messages[index],
            onPermission: (part, allow) {
              c.respondPermission(part: part, allow: allow);
            },
          );
        }
        final perm = c.pendingPermissions[index - c.messages.length];
        // Avoid duplicating permissions already shown inline.
        if (c.messages.any(
          (m) => m.parts.any((p) => p is AgentPermissionPart && p.id == perm.id),
        )) {
          return const SizedBox.shrink();
        }
        return Padding(
          padding: const EdgeInsets.only(bottom: 10),
          child: _PermissionCard(
            part: perm,
            onAllow: () => c.respondPermission(part: perm, allow: true),
            onDeny: () => c.respondPermission(part: perm, allow: false),
          ),
        );
      },
    );
  }

  String _agentCaption(AgentController c) {
    return switch (c.connection) {
      AgentConnectionState.starting => 'Starting agent',
      AgentConnectionState.ready ||
      AgentConnectionState.busy =>
        'Ready',
      AgentConnectionState.idle || AgentConnectionState.error => 'Starting agent',
    };
  }
}

class _GateMessage extends StatelessWidget {
  const _GateMessage({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = ShadTheme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Text(
          text,
          style: theme.textTheme.muted,
          textAlign: TextAlign.center,
        ),
      ),
    );
  }
}

class _AgentIdleArt extends StatelessWidget {
  const _AgentIdleArt({required this.caption});

  final String caption;

  static const _asset = 'assets/robot.webp';

  @override
  Widget build(BuildContext context) {
    final theme = ShadTheme.of(context);
    return LayoutBuilder(
      builder: (context, constraints) {
        final artSize =
            ((constraints.maxWidth * 0.45).clamp(96.0, 220.0)) / 2;
        return Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                SizedBox(
                  width: artSize,
                  height: artSize,
                  child: Image.asset(
                    _asset,
                    fit: BoxFit.contain,
                    alignment: Alignment.center,
                    filterQuality: FilterQuality.medium,
                    gaplessPlayback: true,
                  ),
                ),
                const SizedBox(height: 12),
                Text(
                  caption,
                  style: theme.textTheme.muted,
                  textAlign: TextAlign.center,
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

class _EmptyHint extends StatelessWidget {
  const _EmptyHint({
    required this.icon,
    required this.title,
    required this.subtitle,
  });

  final IconData icon;
  final String title;
  final String subtitle;

  @override
  Widget build(BuildContext context) {
    final theme = ShadTheme.of(context);
    final scheme = theme.colorScheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 28, color: scheme.mutedForeground),
            const SizedBox(height: 12),
            Text(
              title,
              style: theme.textTheme.p.copyWith(fontWeight: FontWeight.w600),
              textAlign: TextAlign.center,
            ),
            if (subtitle.isNotEmpty) ...[
              const SizedBox(height: 6),
              Text(
                subtitle,
                style: theme.textTheme.muted,
                textAlign: TextAlign.center,
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _MessageBubble extends StatelessWidget {
  const _MessageBubble({
    required this.message,
    required this.onPermission,
  });

  final AgentChatMessage message;
  final void Function(AgentPermissionPart part, bool allow) onPermission;

  @override
  Widget build(BuildContext context) {
    final theme = ShadTheme.of(context);
    final scheme = theme.colorScheme;
    final isUser = message.role == AgentMessageRole.user;

    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Align(
        alignment: isUser ? Alignment.centerRight : Alignment.centerLeft,
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxWidth: MediaQuery.sizeOf(context).width * 0.92,
          ),
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: isUser ? scheme.muted : scheme.background,
              borderRadius: BorderRadius.circular(10),
              border: isUser
                  ? null
                  : Border.all(color: scheme.border.withValues(alpha: 0.6)),
            ),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  for (final part in message.parts) ...[
                    if (part is AgentTextPart)
                      isUser
                          ? Text(part.text, style: theme.textTheme.p)
                          : MarkdownBody(
                              data: part.text.isEmpty ? '…' : part.text,
                              selectable: true,
                              styleSheet: MarkdownStyleSheet(
                                p: theme.textTheme.p.copyWith(
                                  color: scheme.foreground,
                                  height: 1.45,
                                ),
                                code: theme.textTheme.small.copyWith(
                                  fontFamily: kMacMonoFont,
                                  backgroundColor: scheme.muted,
                                  color: scheme.foreground,
                                ),
                                codeblockDecoration: BoxDecoration(
                                  color: scheme.muted,
                                  borderRadius: BorderRadius.circular(6),
                                ),
                                a: theme.textTheme.p.copyWith(color: kBrandBlue),
                                listBullet: theme.textTheme.p,
                                h1: theme.textTheme.h3,
                                h2: theme.textTheme.h4,
                                h3: theme.textTheme.p.copyWith(
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            )
                    else if (part is AgentToolPart)
                      Padding(
                        padding: const EdgeInsets.only(top: 6, bottom: 2),
                        child: _ToolRow(part: part),
                      )
                    else if (part is AgentPermissionPart && !part.resolved)
                      Padding(
                        padding: const EdgeInsets.only(top: 8),
                        child: _PermissionCard(
                          part: part,
                          onAllow: () => onPermission(part, true),
                          onDeny: () => onPermission(part, false),
                        ),
                      )
                    else if (part is AgentErrorPart)
                      Padding(
                        padding: const EdgeInsets.only(top: 4),
                        child: Text(
                          part.message,
                          style: theme.textTheme.small.copyWith(
                            color: AppColors.errorRed,
                          ),
                        ),
                      ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _ToolRow extends StatefulWidget {
  const _ToolRow({required this.part});

  final AgentToolPart part;

  @override
  State<_ToolRow> createState() => _ToolRowState();
}

class _ToolRowState extends State<_ToolRow> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final theme = ShadTheme.of(context);
    final scheme = theme.colorScheme;
    final part = widget.part;
    final statusIcon = switch (part.status) {
      AgentToolStatus.pending || AgentToolStatus.running =>
        LucideIcons.loaderCircle,
      AgentToolStatus.completed => LucideIcons.circleCheck,
      AgentToolStatus.error => LucideIcons.circleX,
    };
    final statusColor = switch (part.status) {
      AgentToolStatus.pending || AgentToolStatus.running => kBrandBlue,
      AgentToolStatus.completed => AppColors.successDot,
      AgentToolStatus.error => AppColors.errorRed,
    };

    return DecoratedBox(
      decoration: BoxDecoration(
        color: scheme.muted,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          MouseRegion(
            cursor: SystemMouseCursors.click,
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () => setState(() => _expanded = !_expanded),
              child: Padding(
                padding:
                    const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                child: Row(
                  children: [
                    Icon(statusIcon, size: 14, color: statusColor),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        part.title?.isNotEmpty == true
                            ? part.title!
                            : part.tool,
                        style: theme.textTheme.small.copyWith(
                          fontWeight: FontWeight.w500,
                          fontFamily: kMacMonoFont,
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    Icon(
                      _expanded
                          ? LucideIcons.chevronDown
                          : LucideIcons.chevronRight,
                      size: 14,
                      color: scheme.mutedForeground,
                    ),
                  ],
                ),
              ),
            ),
          ),
          if (_expanded) ...[
            Divider(height: 1, color: scheme.border),
            Padding(
              padding: const EdgeInsets.all(10),
              child: SelectableText(
                [
                  if (part.input != null && part.input!.isNotEmpty)
                    'Input:\n${part.input}',
                  if (part.output != null && part.output!.isNotEmpty)
                    'Output:\n${part.output}',
                  if (part.error != null && part.error!.isNotEmpty)
                    'Error:\n${part.error}',
                ].where((e) => e.isNotEmpty).join('\n\n'),
                style: theme.textTheme.small.copyWith(
                  fontFamily: kMacMonoFont,
                  fontSize: 11,
                  color: scheme.mutedForeground,
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _PermissionCard extends StatelessWidget {
  const _PermissionCard({
    required this.part,
    required this.onAllow,
    required this.onDeny,
  });

  final AgentPermissionPart part;
  final VoidCallback onAllow;
  final VoidCallback onDeny;

  @override
  Widget build(BuildContext context) {
    final theme = ShadTheme.of(context);
    final scheme = theme.colorScheme;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: scheme.muted,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: AppColors.warningAmber.withValues(alpha: 0.5)),
      ),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  LucideIcons.shieldAlert,
                  size: 16,
                  color: AppColors.warningAmber,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    part.title,
                    style: theme.textTheme.small.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            Row(
              children: [
                ShadButton.outline(
                  size: ShadButtonSize.sm,
                  onPressed: onDeny,
                  child: const Text('Deny'),
                ),
                const SizedBox(width: 8),
                ShadButton(
                  size: ShadButtonSize.sm,
                  onPressed: onAllow,
                  child: const Text('Allow'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _Composer extends StatelessWidget {
  const _Composer({
    required this.controller,
    required this.focusNode,
    required this.enabled,
    required this.isBusy,
    required this.onSend,
    required this.onStop,
  });

  final TextEditingController controller;
  final FocusNode focusNode;
  final bool enabled;
  final bool isBusy;
  final VoidCallback? onSend;
  final VoidCallback? onStop;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(10, 8, 10, 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Expanded(
            child: CallbackShortcuts(
              bindings: {
                const SingleActivator(LogicalKeyboardKey.enter): () {
                  if (onSend != null) onSend!();
                },
              },
              child: ShadTextarea(
                controller: controller,
                focusNode: focusNode,
                enabled: enabled && !isBusy,
                placeholder: const Text('What do you want to build?'),
                minHeight: 40,
                maxHeight: 140,
              ),
            ),
          ),
          const SizedBox(width: 8),
          if (isBusy)
            ShadIconButton.destructive(
              icon: const Icon(LucideIcons.square, size: 16),
              onPressed: onStop,
              width: 36,
              height: 36,
            )
          else
            ShadIconButton(
              icon: const Icon(LucideIcons.send, size: 16),
              onPressed: onSend,
              width: 36,
              height: 36,
            ),
        ],
      ),
    );
  }
}
