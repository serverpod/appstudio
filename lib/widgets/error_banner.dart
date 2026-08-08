import 'package:flutter/material.dart';
import 'package:shad/shad.dart';

import '../theme/app_theme.dart';

/// Destructive-tinted failure box with an optional scrollable log tail.
class ErrorBanner extends StatelessWidget {
  const ErrorBanner({super.key, required this.message, this.log});

  final String message;

  /// Command output shown in a capped, scrollable monospace pane.
  final String? log;

  @override
  Widget build(BuildContext context) {
    final theme = ShadTheme.of(context);
    final scheme = theme.colorScheme;

    return Container(
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
      decoration: BoxDecoration(
        color: scheme.destructive.withValues(alpha: 0.08),
        borderRadius: theme.radii.md,
        border: Border.all(color: scheme.destructive.withValues(alpha: 0.35)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(
                LucideIcons.circleAlert,
                size: 14,
                color: scheme.destructive,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  message,
                  // `muted`, not `small`: failure messages wrap, and `small` is
                  // the label role (`leading-none`), which sets them solid.
                  style: theme.textTheme.muted.copyWith(
                    color: scheme.destructive,
                  ),
                ),
              ),
            ],
          ),
          if (log != null && log!.isNotEmpty) ...[
            const SizedBox(height: 8),
            ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 120),
              child: SingleChildScrollView(
                child: Text(
                  log!,
                  style: theme.textTheme.muted.copyWith(
                    fontFamily: kMacMonoFont,
                    fontSize: 10.5,
                    height: 1.4,
                  ),
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}
