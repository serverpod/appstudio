import 'package:appstudio/toolchain/tool_status.dart';
import 'package:appstudio/ui/uninstall/uninstall_confirm_dialog.dart';
import 'package:appstudio/ui/uninstall/uninstalled_screen.dart';
import 'package:appstudio/uninstall/uninstall_result.dart';
import 'package:widgetbook/widgetbook.dart';

import '../host.dart';
import '../studio_window.dart';

DialogUseCase _confirm(List<ToolId> removable) => DialogUseCase(
      backdrop: const StudioWindowMock(),
      dialog: UninstallConfirmDialog(
        measureBytes: () async => 48 * 1000 * 1000,
        removableTools: removable,
      ),
    );

final uninstallFolder = WidgetbookFolder(
  name: 'Uninstall',
  children: [
    WidgetbookComponent(
      name: 'Confirm',
      useCases: [
        WidgetbookUseCase(
          name: 'App Studio installed everything',
          builder: (_) => _confirm(const [
            ToolId.serverpodCli,
            ToolId.flutter,
            ToolId.commandLineTools,
          ]),
        ),
        WidgetbookUseCase(
          name: 'App Studio installed Flutter and the CLI',
          builder: (_) =>
              _confirm(const [ToolId.serverpodCli, ToolId.flutter]),
        ),
        WidgetbookUseCase(
          name: 'App Studio installed no tools',
          builder: (_) => _confirm(const []),
        ),
      ],
    ),
    WidgetbookComponent(
      name: 'Progress and result',
      useCases: [
        WidgetbookUseCase(
          name: 'Uninstalling',
          builder: (_) => screen(const UninstallingScreen()),
        ),
        WidgetbookUseCase(
          name: 'Uninstalled',
          builder: (_) => screen(
            const UninstalledScreen(result: UninstallResult(failures: [])),
          ),
        ),
        WidgetbookUseCase(
          name: 'Some steps failed',
          builder: (_) => screen(
            const UninstalledScreen(
              result: UninstallResult(
                failures: [
                  'uninstalling the Command Line Tools',
                  'deleting the App Studio support folder',
                ],
              ),
            ),
          ),
        ),
      ],
    ),
  ],
);
