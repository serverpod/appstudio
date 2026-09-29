import 'package:flutter/material.dart';
import 'package:shad/shad.dart';

import '../../theme/app_theme.dart';
import '../../uninstall/uninstall_result.dart';
import '../landing_scaffold.dart';

/// The last thing App Studio shows: everything is gone, you can delete the app.
///
/// Deliberately a dead end — no buttons, no way back. The session is torn down,
/// the toolchain is deleted and preferences are cleared, so every control the
/// app normally offers would either fail or silently recreate what was just
/// removed. A screen that only tells the truth is better than one that looks
/// operable and is not.
///
/// On the landing backdrop, like the start page and the setup screen: with no
/// project, no toolchain and no session, this is the app back at its own front
/// door — and the branded gradient is the one surface here that does not
/// depend on anything that was just deleted.
class UninstalledScreen extends StatelessWidget {
  const UninstalledScreen({super.key, required this.result});

  final UninstallResult result;

  @override
  Widget build(BuildContext context) =>
      LandingScaffold(child: _UninstalledContent(result: result));
}

/// Split out so it builds *beneath* [LandingScaffold] and reads the landing
/// theme rather than the app's. Every colour here is set explicitly for the
/// same reason it is on the start page: a text role with no colour of its own
/// falls through to the `DefaultTextStyle` `ShadApp` installed from the app
/// theme, which follows the system's light/dark setting — and would put black
/// text on the gradient.
class _UninstalledContent extends StatelessWidget {
  const _UninstalledContent({required this.result});

  final UninstallResult result;

  @override
  Widget build(BuildContext context) {
    final theme = ShadTheme.of(context);
    final scheme = theme.colorScheme;

    return Padding(
      padding: const EdgeInsets.all(32),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                result.isClean ? LucideIcons.circleCheck : LucideIcons.info,
                size: 40,
                color: result.isClean ? scheme.foreground : scheme.warning,
              ),
              const SizedBox(height: 20),
              Text(
                result.isClean
                    ? 'App Studio has been uninstalled'
                    : 'App Studio has been mostly uninstalled',
                style: theme.textTheme.h4.copyWith(color: scheme.foreground),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 10),
              Text(
                result.isClean
                    ? 'All supporting files have been deleted. You can now '
                        'safely move App Studio to the Trash.'
                    : 'Most supporting files have been deleted. You can now '
                        'safely move App Studio to the Trash.',
                style: theme.textTheme.muted.copyWith(
                  color: scheme.mutedForeground,
                ),
                textAlign: TextAlign.center,
              ),
              // Never claim a clean uninstall that did not happen — someone
              // deleting an app for privacy reasons deserves to know what is
              // still on their disk.
              if (!result.isClean) ...[
                const SizedBox(height: 16),
                Text(
                  'These steps did not complete:',
                  style: theme.textTheme.small.copyWith(
                    color: scheme.foreground,
                  ),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 4),
                for (final failure in result.failures)
                  Text(
                    '• $failure',
                    style: theme.textTheme.muted.copyWith(
                      fontSize: 11,
                      color: scheme.mutedForeground,
                    ),
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

/// Shown while the uninstall runs. Brief, but the teardown can take a few
/// seconds and a frozen IDE would read as a hang.
///
/// On the same backdrop as [UninstalledScreen], which it hands straight over
/// to: two treatments across one uninstall would read as the window being
/// replaced twice.
class UninstallingScreen extends StatelessWidget {
  const UninstallingScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return LandingScaffold(
      // Built under the scaffold, so it is the landing theme being read here
      // and the colour is white rather than the app's foreground.
      child: Builder(
        builder: (context) {
          final theme = ShadTheme.of(context);
          return Center(
            child: Text(
              'Uninstalling…',
              style: theme.textTheme.muted.copyWith(
                color: theme.colorScheme.foreground,
              ),
            ),
          );
        },
      ),
    );
  }
}
