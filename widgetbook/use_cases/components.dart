import 'package:appstudio/theme/app_theme.dart';
import 'package:appstudio/widgets/command_block.dart';
import 'package:appstudio/widgets/determinate_progress.dart';
import 'package:appstudio/widgets/error_banner.dart';
import 'package:appstudio/widgets/settings_table.dart';
import 'package:appstudio/widgets/toolbar_action_button.dart';
import 'package:flutter/material.dart';
import 'package:shad/shad.dart';
import 'package:widgetbook/widgetbook.dart';

import '../host.dart';

/// The shared building blocks, on their own. Everything above uses them in
/// context; these are for changing one and seeing every state at once.
final componentsFolder = WidgetbookFolder(
  name: 'Components',
  children: [
    WidgetbookComponent(
      name: 'Error banner',
      useCases: [
        WidgetbookUseCase(
          name: 'Message',
          builder: (_) => const ComponentCanvas(
            child: ErrorBanner(
              message: 'Download failed. Check your internet connection and '
                  'try again.',
            ),
          ),
        ),
        WidgetbookUseCase(
          name: 'With log',
          builder: (_) => const ComponentCanvas(
            child: ErrorBanner(
              message: 'serverpod create failed (exit code 1).',
              log: 'Creating project "bookshelf"…\n'
                  'Resolving dependencies…\n'
                  'Error: Directory ~/Projects/bookshelf already exists.',
            ),
          ),
        ),
      ],
    ),
    WidgetbookComponent(
      name: 'Command block',
      useCases: [
        WidgetbookUseCase(
          name: 'One command',
          builder: (_) => const ComponentCanvas(
            child: CommandBlock(command: '~/flutter/bin/flutter upgrade'),
          ),
        ),
        WidgetbookUseCase(
          name: 'Several lines',
          builder: (_) => const ComponentCanvas(
            child: CommandBlock(
              command: '~/flutter/bin/flutter channel stable\n'
                  '~/flutter/bin/flutter upgrade',
            ),
          ),
        ),
      ],
    ),
    WidgetbookComponent(
      name: 'Progress',
      useCases: [
        WidgetbookUseCase(
          name: 'Determinate',
          builder: (_) => ComponentCanvas(
            child: DeterminateProgress(
              fraction: 0.38,
              caption: formatTransferCaption(
                received: 871 * 1000 * 1000,
                total: 2262 * 1000 * 1000,
                eta: const Duration(minutes: 1, seconds: 4),
              ),
            ),
          ),
        ),
        WidgetbookUseCase(
          name: 'Indeterminate',
          builder: (_) => const ComponentCanvas(
            child: DeterminateProgress(
              fraction: null,
              caption: 'Step 3 of 3 · Running dart install serverpod_cli.',
            ),
          ),
        ),
      ],
    ),
    WidgetbookComponent(
      name: 'Settings table',
      useCases: [
        WidgetbookUseCase(
          name: 'Tools',
          builder: (_) => ComponentCanvas(
            child: Builder(
              builder: (context) {
                final theme = ShadTheme.of(context);
                return SettingsTable(
                  rows: [
                    SettingsTableRow(
                      name: 'Command Line Tools',
                      trailing: appSuccessBadge(
                        theme,
                        child: const Text('Native'),
                      ),
                    ),
                    SettingsTableRow(
                      name: 'Flutter SDK',
                      badge: versionBadge('3.47.5'),
                      trailing: appSuccessBadge(
                        theme,
                        child: const Text('App Studio'),
                      ),
                    ),
                    SettingsTableRow(
                      name: 'Serverpod CLI',
                      badge: versionBadge('4.0.3', replacing: '3.4.1'),
                      trailing: appWarningBadge(
                        theme,
                        child: const Text('Update needed'),
                      ),
                    ),
                  ],
                );
              },
            ),
          ),
        ),
      ],
    ),
    WidgetbookComponent(
      name: 'Toolbar action button',
      useCases: [
        for (final (name, busy, failed, enabled) in [
          ('Idle', false, false, true),
          ('Busy', true, false, true),
          ('Failed', false, true, true),
          ('Disabled', false, false, false),
        ])
          WidgetbookUseCase(
            name: name,
            builder: (_) => ComponentCanvas(
              width: null,
              child: ToolbarActionButton(
                label: 'Full Restart',
                icon: LucideIcons.rotateCcw,
                tooltip: 'Full restart',
                busy: busy,
                failed: failed,
                onPressed: enabled ? () {} : null,
              ),
            ),
          ),
      ],
    ),
  ],
);
