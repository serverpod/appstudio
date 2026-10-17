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
        // Top, so with several lines the copy button stays in the corner
        // rather than drifting to the middle.
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Padding(
              // Centres a single line on the button beside it.
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: SelectableText(
                widget.command,
                // `small` is `leading-none`: fine for one line, cramped for
                // two. Commands wrap onto several lines, so give them room.
                style: theme.textTheme.small.copyWith(
                  fontFamily: kMonoFont,
                  height: 1.7,
                ),
              ),
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
