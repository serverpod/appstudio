import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:shadcn_ui/shadcn_ui.dart';
import 'package:shimmer/shimmer.dart';

import '../../agent/agent_controller.dart';
import '../../agent/agent_transcript.dart';
import '../../process/serverpod_process.dart';
import '../../theme/app_colors.dart';
import '../../theme/app_theme.dart';
import '../../widgets/menu_item_tile.dart';

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
              agent: c,
              controller: _inputController,
              focusNode: _inputFocus,
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
      itemCount: c.messages.length +
          c.pendingPermissions.length +
          (_showTrailingThinking(c) ? 1 : 0),
      itemBuilder: (context, index) {
        if (index < c.messages.length) {
          final message = c.messages[index];
          if (_isVisuallyEmptyAssistant(message)) {
            return c.isBusy
                ? _ThinkingStatus(label: _thinkingLabel(c))
                : const SizedBox.shrink();
          }
          return _MessageBubble(
            message: message,
            onPermission: (part, allow) {
              c.respondPermission(part: part, allow: allow);
            },
          );
        }
        final permIndex = index - c.messages.length;
        if (permIndex < c.pendingPermissions.length) {
          final perm = c.pendingPermissions[permIndex];
          // Avoid duplicating permissions already shown inline.
          if (c.messages.any(
            (m) => m.parts.any(
              (p) => p is AgentPermissionPart && p.id == perm.id,
            ),
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
        }
        return _ThinkingStatus(label: _thinkingLabel(c));
      },
    );
  }

  bool _showTrailingThinking(AgentController c) {
    if (!c.isBusy || c.messages.isEmpty) return false;
    final last = c.messages.last;
    return last.role == AgentMessageRole.user;
  }

  bool _isVisuallyEmptyAssistant(AgentChatMessage message) {
    if (message.role != AgentMessageRole.assistant) return false;
    for (final part in message.parts) {
      if (part is AgentTextPart && part.text.trim().isNotEmpty) return false;
      if (part is AgentToolPart) return false;
      if (part is AgentPermissionPart && !part.resolved) return false;
      if (part is AgentErrorPart) return false;
    }
    return true;
  }

  String _thinkingLabel(AgentController c) {
    return switch (c.mode) {
      AgentChatMode.plan => 'Planning next moves',
      AgentChatMode.agent => 'Thinking',
    };
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

class _ThinkingStatus extends StatelessWidget {
  const _ThinkingStatus({required this.label});

  final String label;

  /// Matches assistant bubble text inset: 1px border + 12px padding.
  static const _bubbleTextInset = 1.0 + 12.0;

  @override
  Widget build(BuildContext context) {
    final theme = ShadTheme.of(context);
    final scheme = theme.colorScheme;
    final style = theme.textTheme.small.copyWith(
      fontSize: 13,
      color: scheme.mutedForeground,
      height: 1.4,
    );

    return Padding(
      padding: const EdgeInsets.only(
        left: _bubbleTextInset,
        bottom: 12,
        top: 2,
      ),
      child: Align(
        alignment: Alignment.centerLeft,
        child: Shimmer.fromColors(
          baseColor: scheme.mutedForeground.withValues(alpha: 0.45),
          highlightColor: scheme.foreground.withValues(alpha: 0.85),
          period: const Duration(milliseconds: 1400),
          child: Text(label, style: style),
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
    final bodyStyle = theme.textTheme.small.copyWith(
      fontSize: 13,
      color: scheme.foreground,
      height: 1.4,
    );
    final codeStyle = theme.textTheme.small.copyWith(
      fontFamily: kMacMonoFont,
      fontSize: 12,
      height: 1.55,
      backgroundColor: scheme.muted,
      color: scheme.foreground,
    );

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
                    if (part is AgentTextPart && part.text.trim().isNotEmpty)
                      isUser
                          ? Text(part.text, style: bodyStyle)
                          : MarkdownBody(
                              data: part.text,
                              selectable: true,
                              styleSheet: MarkdownStyleSheet(
                                p: bodyStyle,
                                code: codeStyle,
                                codeblockPadding: const EdgeInsets.fromLTRB(
                                  12,
                                  10,
                                  12,
                                  10,
                                ),
                                codeblockDecoration: BoxDecoration(
                                  color: scheme.muted,
                                  borderRadius: BorderRadius.circular(6),
                                ),
                                a: bodyStyle.copyWith(color: kBrandBlue),
                                listBullet: bodyStyle,
                                h1: bodyStyle.copyWith(
                                  fontSize: 15,
                                  fontWeight: FontWeight.w600,
                                ),
                                h2: bodyStyle.copyWith(
                                  fontSize: 14,
                                  fontWeight: FontWeight.w600,
                                ),
                                h3: bodyStyle.copyWith(
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
                            fontSize: 13,
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
    final spinning = part.status == AgentToolStatus.pending ||
        part.status == AgentToolStatus.running;

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
                    if (spinning)
                      _SpinningIcon(
                        icon: statusIcon,
                        size: 14,
                        color: statusColor,
                      )
                    else
                      Icon(statusIcon, size: 14, color: statusColor),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        part.title?.isNotEmpty == true
                            ? part.title!
                            : part.tool,
                        style: theme.textTheme.small.copyWith(
                          fontSize: 12,
                          fontWeight: FontWeight.w500,
                          fontFamily: kMacMonoFont,
                          height: 1.35,
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
                  height: 1.55,
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

class _SpinningIcon extends StatefulWidget {
  const _SpinningIcon({
    required this.icon,
    required this.size,
    required this.color,
  });

  final IconData icon;
  final double size;
  final Color color;

  @override
  State<_SpinningIcon> createState() => _SpinningIconState();
}

class _SpinningIconState extends State<_SpinningIcon>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 900),
    )..repeat();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return RotationTransition(
      turns: _controller,
      child: Icon(widget.icon, size: widget.size, color: widget.color),
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

class _Composer extends StatefulWidget {
  const _Composer({
    required this.agent,
    required this.controller,
    required this.focusNode,
    required this.onSend,
    required this.onStop,
  });

  final AgentController agent;
  final TextEditingController controller;
  final FocusNode focusNode;
  final VoidCallback? onSend;
  final VoidCallback? onStop;

  @override
  State<_Composer> createState() => _ComposerState();
}

class _ComposerState extends State<_Composer> {
  static const _maxLines = 15;
  static const _addModelSentinel = '__add_model__';

  late final ShadPopoverController _modePopover;
  late final ShadPopoverController _modelPopover;
  bool _hasText = false;

  @override
  void initState() {
    super.initState();
    _modePopover = ShadPopoverController();
    _modelPopover = ShadPopoverController();
    _hasText = widget.controller.text.trim().isNotEmpty;
    widget.controller.addListener(_onTextChanged);
  }

  @override
  void dispose() {
    widget.controller.removeListener(_onTextChanged);
    _modePopover.dispose();
    _modelPopover.dispose();
    super.dispose();
  }

  void _onTextChanged() {
    final next = widget.controller.text.trim().isNotEmpty;
    if (next != _hasText) setState(() => _hasText = next);
  }

  IconData _modeIcon(AgentChatMode mode) => switch (mode) {
        AgentChatMode.agent => LucideIcons.infinity,
        AgentChatMode.plan => LucideIcons.listChecks,
      };

  String _shortModelLabel(AgentModelOption model) {
    final slash = model.label.lastIndexOf('/');
    if (slash >= 0 && slash < model.label.length - 1) {
      return model.label.substring(slash + 1).trim();
    }
    return model.label;
  }

  @override
  Widget build(BuildContext context) {
    final theme = ShadTheme.of(context);
    final scheme = theme.colorScheme;
    final agent = widget.agent;
    final canSend = widget.onSend != null && _hasText;
    final isBusy = agent.isBusy;
    final textStyle = theme.textTheme.small.copyWith(height: 1.4);
    final hintStyle = theme.textTheme.muted.copyWith(
      height: 1.4,
      color: scheme.mutedForeground,
    );

    return Padding(
      padding: const EdgeInsets.fromLTRB(10, 8, 10, 10),
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: scheme.card,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: scheme.border),
        ),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 10, 12, 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              CallbackShortcuts(
                bindings: {
                  const SingleActivator(LogicalKeyboardKey.enter): () {
                    if (canSend) widget.onSend!();
                  },
                },
                child: Material(
                  type: MaterialType.transparency,
                  child: TextField(
                    controller: widget.controller,
                    focusNode: widget.focusNode,
                    enabled: agent.canSend,
                    minLines: 1,
                    maxLines: _maxLines,
                    style: textStyle,
                    cursorColor: scheme.foreground,
                    keyboardType: TextInputType.multiline,
                    textInputAction: TextInputAction.newline,
                    decoration: InputDecoration(
                      isDense: true,
                      border: InputBorder.none,
                      enabledBorder: InputBorder.none,
                      focusedBorder: InputBorder.none,
                      disabledBorder: InputBorder.none,
                      filled: false,
                      hintText: 'What do you want to build?',
                      hintStyle: hintStyle,
                      contentPadding: EdgeInsets.zero,
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  Expanded(
                    child: Row(
                      children: [
                        _ModeChip(
                          popover: _modePopover,
                          mode: agent.mode,
                          icon: _modeIcon(agent.mode),
                          onSelect: (mode) {
                            _modePopover.setOpen(false);
                            agent.setMode(mode);
                          },
                          modeIcon: _modeIcon,
                        ),
                        const SizedBox(width: 6),
                        Flexible(
                          child: _ModelPicker(
                            popover: _modelPopover,
                            label: agent.defaultModelLabel ?? 'Select model',
                            models: agent.availableModels,
                            selectedValue: agent.defaultModel,
                            shortLabel: _shortModelLabel,
                            onSelect: (value) {
                              _modelPopover.setOpen(false);
                              if (value == _addModelSentinel) {
                                agent.openSettings();
                                return;
                              }
                              agent.setDefaultModel(value);
                            },
                            addModelValue: _addModelSentinel,
                          ),
                        ),
                      ],
                    ),
                  ),
                  if (isBusy)
                    _CircleAction(
                      background: AppColors.errorRed,
                      foreground: Colors.white,
                      icon: LucideIcons.square,
                      iconSize: 11,
                      onPressed: widget.onStop,
                    )
                  else
                    _CircleAction(
                      background: canSend
                          ? scheme.foreground
                          : scheme.mutedForeground.withValues(alpha: 0.35),
                      foreground: scheme.background,
                      icon: LucideIcons.arrowUp,
                      iconSize: 13,
                      onPressed: canSend ? widget.onSend : null,
                    ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ModeChip extends StatelessWidget {
  const _ModeChip({
    required this.popover,
    required this.mode,
    required this.icon,
    required this.onSelect,
    required this.modeIcon,
  });

  final ShadPopoverController popover;
  final AgentChatMode mode;
  final IconData icon;
  final ValueChanged<AgentChatMode> onSelect;
  final IconData Function(AgentChatMode mode) modeIcon;

  @override
  Widget build(BuildContext context) {
    final theme = ShadTheme.of(context);
    final scheme = theme.colorScheme;

    return ShadPopover(
      controller: popover,
      padding: const EdgeInsets.all(4),
      popover: (context) => SizedBox(
        width: 160,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final option in AgentChatMode.values)
              MenuItemTile(
                icon: modeIcon(option),
                label: option.label,
                onTap: () => onSelect(option),
              ),
          ],
        ),
      ),
      child: _ComposerChipButton(
        onPressed: popover.toggle,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 13, color: scheme.foreground),
            const SizedBox(width: 5),
            Text(
              mode.label,
              style: theme.textTheme.small.copyWith(
                fontWeight: FontWeight.w500,
                fontSize: 12,
              ),
            ),
            const SizedBox(width: 2),
            Icon(
              LucideIcons.chevronDown,
              size: 12,
              color: scheme.mutedForeground,
            ),
          ],
        ),
      ),
    );
  }
}

class _ModelPicker extends StatelessWidget {
  const _ModelPicker({
    required this.popover,
    required this.label,
    required this.models,
    required this.selectedValue,
    required this.shortLabel,
    required this.onSelect,
    required this.addModelValue,
  });

  final ShadPopoverController popover;
  final String label;
  final List<AgentModelOption> models;
  final String? selectedValue;
  final String Function(AgentModelOption model) shortLabel;
  final ValueChanged<String> onSelect;
  final String addModelValue;

  @override
  Widget build(BuildContext context) {
    final theme = ShadTheme.of(context);
    final scheme = theme.colorScheme;
    final display = () {
      final value = selectedValue;
      if (value == null) return label;
      for (final m in models) {
        if (m.value == value) return shortLabel(m);
      }
      final slash = value.indexOf('/');
      if (slash >= 0 && slash < value.length - 1) {
        return value.substring(slash + 1);
      }
      return label;
    }();

    return ShadPopover(
      controller: popover,
      padding: const EdgeInsets.all(4),
      popover: (context) => ConstrainedBox(
        constraints: const BoxConstraints(minWidth: 220, maxWidth: 320, maxHeight: 280),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              for (final model in models)
                MenuItemTile(
                  icon: model.value == selectedValue
                      ? LucideIcons.check
                      : null,
                  reserveIconSpace: true,
                  label: shortLabel(model),
                  subtitle: model.providerId,
                  onTap: () => onSelect(model.value),
                ),
              if (models.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  child: Divider(height: 1, color: scheme.border),
                ),
              MenuItemTile(
                icon: LucideIcons.plus,
                reserveIconSpace: true,
                label: 'Add model...',
                onTap: () => onSelect(addModelValue),
              ),
            ],
          ),
        ),
      ),
      child: _ComposerChipButton(
        filled: false,
        onPressed: popover.toggle,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 180),
              child: Text(
                display,
                style: theme.textTheme.small.copyWith(
                  fontSize: 12,
                  color: scheme.foreground,
                ),
                overflow: TextOverflow.ellipsis,
              ),
            ),
            const SizedBox(width: 2),
            Icon(
              LucideIcons.chevronDown,
              size: 12,
              color: scheme.mutedForeground,
            ),
          ],
        ),
      ),
    );
  }
}

class _ComposerChipButton extends StatefulWidget {
  const _ComposerChipButton({
    required this.onPressed,
    required this.child,
    this.filled = true,
  });

  final VoidCallback onPressed;
  final Widget child;
  final bool filled;

  @override
  State<_ComposerChipButton> createState() => _ComposerChipButtonState();
}

class _ComposerChipButtonState extends State<_ComposerChipButton> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final scheme = ShadTheme.of(context).colorScheme;
    final bg = widget.filled
        ? (_hovered ? scheme.muted.withValues(alpha: 0.9) : scheme.muted)
        : (_hovered ? scheme.muted.withValues(alpha: 0.45) : Colors.transparent);

    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        onTap: widget.onPressed,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 100),
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
          decoration: BoxDecoration(
            color: bg,
            borderRadius: BorderRadius.circular(999),
          ),
          child: widget.child,
        ),
      ),
    );
  }
}

class _CircleAction extends StatelessWidget {
  const _CircleAction({
    required this.background,
    required this.foreground,
    required this.icon,
    required this.onPressed,
    this.iconSize = 15,
  });

  final Color background;
  final Color foreground;
  final IconData icon;
  final VoidCallback? onPressed;
  final double iconSize;

  @override
  Widget build(BuildContext context) {
    final enabled = onPressed != null;
    return MouseRegion(
      cursor:
          enabled ? SystemMouseCursors.click : SystemMouseCursors.basic,
      child: GestureDetector(
        onTap: onPressed,
        child: AnimatedOpacity(
          duration: const Duration(milliseconds: 100),
          opacity: enabled ? 1 : 0.55,
          child: Container(
            width: 24,
            height: 24,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: background,
              shape: BoxShape.circle,
            ),
            child: Icon(icon, size: iconSize, color: foreground),
          ),
        ),
      ),
    );
  }
}
