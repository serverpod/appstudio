import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shad/shad.dart';

import '../theme/app_theme.dart';

/// Shell commands for the user to run themselves, with a copy button.
class CommandBlock extends StatefulWidget {
  const CommandBlock({super.key, required this.command});

  /// One command per line.
  final String command;

  @override
  State<CommandBlock> createState() => _CommandBlockState();
}

class _CommandBlockState extends State<CommandBlock> {
  bool _copied = false;

  Future<void> _copy() async {
    await Clipboard.setData(ClipboardData(text: widget.command));
    if (mounted) setState(() => _copied = true);
  }

  @override
  Widget build(BuildContext context) {
    final theme = ShadTheme.of(context);
    return ShadCard(
      backgroundColor: theme.colorScheme.muted,
      padding: const EdgeInsets.fromLTRB(12, 4, 4, 4),
      child: Row(
        children: [
          Expanded(
            child: SelectableText(
              widget.command,
              style: theme.textTheme.small.copyWith(fontFamily: kMacMonoFont),
            ),
          ),
          ShadTooltip(
            builder: (context) => Text(_copied ? 'Copied' : 'Copy'),
            child: ShadIconButton.ghost(
              icon: Icon(
                _copied ? LucideIcons.check : LucideIcons.copy,
                size: 14,
              ),
              onPressed: _copy,
            ),
          ),
        ],
      ),
    );
  }
}
