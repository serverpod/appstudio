import 'package:flutter/material.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

import '../../uninstall/uninstaller.dart';

/// The last thing App Studio shows: everything is gone, you can delete the app.
///
/// Deliberately a dead end — no buttons, no way back. The session is torn down,
/// the toolchain is deleted and preferences are cleared, so every control the
/// app normally offers would either fail or silently recreate what was just
/// removed. A screen that only tells the truth is better than one that looks
/// operable and is not.
class UninstalledScreen extends StatelessWidget {
  const UninstalledScreen({super.key, required this.result});

  final UninstallResult result;

  @override
  Widget build(BuildContext context) {
    final theme = ShadTheme.of(context);
    final scheme = theme.colorScheme;

    return ColoredBox(
      color: scheme.background,
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                result.isClean ? LucideIcons.circleCheck : LucideIcons.info,
                size: 40,
                color: result.isClean ? scheme.mutedForeground : scheme.primary,
              ),
              const SizedBox(height: 20),
              Text(
                result.isClean
                    ? 'App Studio has been uninstalled'
                    : 'App Studio has been mostly uninstalled',
                style: theme.textTheme.h4,
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 10),
              Text(
                result.isClean
                    ? 'All supporting files have been deleted. You can now '
                        'safely move App Studio to the Trash.'
                    : 'Most supporting files have been deleted. You can now '
                        'safely move App Studio to the Trash.',
                style: theme.textTheme.muted,
                textAlign: TextAlign.center,
              ),
              // Never claim a clean uninstall that did not happen — someone
              // deleting an app for privacy reasons deserves to know what is
              // still on their disk.
              if (!result.isClean) ...[
                const SizedBox(height: 16),
                Text(
                  'These steps did not complete:',
                  style: theme.textTheme.small,
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 4),
                for (final failure in result.failures)
                  Text(
                    '• $failure',
                    style: theme.textTheme.muted.copyWith(fontSize: 11),
                    textAlign: TextAlign.center,
                  ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
