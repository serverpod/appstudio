import 'dart:async';

import 'package:appstudio/platform/linux/app_version.dart';
import 'package:appstudio/process/ide_integration.dart';
import 'package:appstudio/process/new_project_view.dart';
import 'package:appstudio/ui/add_to_applications_dialog.dart';
import 'package:appstudio/ui/new_project_dialog.dart';
import 'package:appstudio/ui/start_page.dart';
import 'package:appstudio/update/linux/appcast.dart';
import 'package:appstudio/update/linux/linux_update_dialog.dart';
import 'package:appstudio/update/linux/update_signals.dart';
import 'package:flutter/material.dart';
import 'package:widgetbook/widgetbook.dart';

import '../fakes/project.dart';
import '../host.dart';

Widget _startPage(FakeRecentProjects session) => screen(
      ListenableBuilder(
        listenable: session,
        builder: (context, _) =>
            StartPage(session: session, onNewProject: () {}),
      ),
    );

/// The New Project screen in one state. With [createOnOpen] it presses
/// Create itself, so the progress and failure states need no clicking.
Widget _createProject(
  NewProjectView actions, {
  String name = '',
  IdeIntegration? ide,
  bool createOnOpen = false,
}) =>
    screen(
      NewProjectScreen(
        actions: actions,
        initialName: name,
        initialIde: ide,
        createOnOpen: createOnOpen,
      ),
    );

final _sampleUpdate = AppcastItem(
  version: const AppVersion('0.4.2', 26),
  url: Uri.parse('https://example.com/AppStudio-0.4.2-x86_64.AppImage'),
  length: 143997432,
  signature: '',
);

/// The catalog never installs: Install and Restart waits forever.
Future<bool> _neverInstalls(
  AppcastItem item, {
  required void Function(int received, int total) onProgress,
  required UpdateCancellation cancellation,
}) =>
    Completer<bool>().future;

/// A Linux dialog over the start page, where the question on first start
/// appears.
DialogUseCase _overStartPage(Widget dialog) => DialogUseCase(
      backdrop: StartPage(session: FakeRecentProjects(), onNewProject: () {}),
      dialog: dialog,
    );

final startFolder = WidgetbookFolder(
  name: 'Start',
  children: [
    WidgetbookComponent(
      name: 'Start page',
      useCases: [
        WidgetbookUseCase(
          name: 'First time',
          builder: (_) => _startPage(FakeRecentProjects()),
        ),
        WidgetbookUseCase(
          name: 'With recent projects',
          builder: (_) => _startPage(
            FakeRecentProjects(
              recents: [
                homePath('Projects/bookshelf'),
                homePath('Projects/clients/acme_portal'),
                homePath('Desktop/todo_app'),
              ],
            ),
          ),
        ),
        WidgetbookUseCase(
          name: 'Not a Serverpod project',
          builder: (_) => _startPage(
            FakeRecentProjects(
              recents: [homePath('Projects/bookshelf')],
              error: 'Not a Serverpod project. Open a folder with a pubspec '
                  'that depends on serverpod.',
            ),
          ),
        ),
      ],
    ),
    WidgetbookComponent(
      name: 'New Project',
      useCases: [
        WidgetbookUseCase(
          name: 'Empty',
          builder: (_) => _createProject(FakeNewProject()),
        ),
        WidgetbookUseCase(
          name: 'Invalid name',
          builder: (_) => _createProject(FakeNewProject(), name: '2nd_app'),
        ),
        WidgetbookUseCase(
          name: 'Filled in',
          builder: (_) => _createProject(
            FakeNewProject(),
            name: 'bookshelf',
            ide: IdeIntegration.cursor,
          ),
        ),
        WidgetbookUseCase(
          name: 'Creating',
          builder: (_) => _createProject(
            FakeNewProject(outcome: CreateOutcome.hangs),
            name: 'bookshelf',
            ide: IdeIntegration.claude,
            createOnOpen: true,
          ),
        ),
        WidgetbookUseCase(
          name: 'CLI failed',
          builder: (_) => _createProject(
            FakeNewProject(outcome: CreateOutcome.fails),
            name: 'bookshelf',
            ide: IdeIntegration.vscode,
            createOnOpen: true,
          ),
        ),
        WidgetbookUseCase(
          name: 'CLI crashed',
          builder: (_) => _createProject(
            FakeNewProject(outcome: CreateOutcome.crashes),
            name: 'bookshelf',
            ide: IdeIntegration.cursor,
            createOnOpen: true,
          ),
        ),
        WidgetbookUseCase(
          name: 'Created but not configured',
          builder: (_) => _createProject(
            FakeNewProject(outcome: CreateOutcome.partlyCreated),
            name: 'bookshelf',
            ide: IdeIntegration.cursor,
            createOnOpen: true,
          ),
        ),
      ],
    ),
    WidgetbookComponent(
      name: 'Add to Applications (Linux)',
      useCases: [
        WidgetbookUseCase(
          name: 'On first start',
          builder: (_) => _overStartPage(
            AddToApplicationsDialog(
              onAdd: () async {},
              currentFolder: homePath('Downloads'),
            ),
          ),
        ),
        WidgetbookUseCase(
          name: 'Already in ~/AppImages',
          builder: (_) =>
              _overStartPage(AddToApplicationsDialog(onAdd: () async {})),
        ),
        WidgetbookUseCase(
          name: 'From a folder it can only copy from',
          builder: (_) => _overStartPage(
            AddToApplicationsDialog(
              onAdd: () async {},
              currentFolder: '/opt/as',
              keepsOriginal: true,
            ),
          ),
        ),
        WidgetbookUseCase(
          name: 'Replacing a copy left in ~/AppImages',
          builder: (_) => _overStartPage(
            AddToApplicationsDialog(
              onAdd: () async {},
              currentFolder: homePath('Downloads'),
              replacedFile: homePath('AppImages/AppStudio-x86_64.AppImage'),
            ),
          ),
        ),
        WidgetbookUseCase(
          name: 'From the Help menu',
          builder: (_) => _overStartPage(
            AddToApplicationsDialog(
              onAdd: () async {},
              currentFolder: homePath('Downloads'),
              offerDontAskAgain: false,
            ),
          ),
        ),
      ],
    ),
    WidgetbookComponent(
      name: 'Another copy (Linux)',
      useCases: [
        WidgetbookUseCase(
          name: 'Newer than the one in the app menu',
          builder: (_) => _overStartPage(
            ReplaceAddedCopyDialog(
              running: const AppVersion('0.4.2', 26),
              added: const AppVersion('0.4.1', 25),
              currentFolder: homePath('Downloads'),
              onReplace: () async {},
            ),
          ),
        ),
        WidgetbookUseCase(
          name: 'Older than the one in the app menu',
          builder: (_) => _overStartPage(
            const OlderCopyDialog(
              running: AppVersion('0.4.0', 24),
              added: AppVersion('0.4.1', 25),
            ),
          ),
        ),
      ],
    ),
    WidgetbookComponent(
      name: 'Update (Linux)',
      useCases: [
        WidgetbookUseCase(
          name: 'Checking',
          builder: (_) => _overStartPage(
            LinuxUpdateDialog.check(
              current: const AppVersion('0.4.1', 25),
              check: () => Completer<AppcastItem?>().future,
              install: _neverInstalls,
            ),
          ),
        ),
        WidgetbookUseCase(
          name: 'Up to date',
          builder: (_) => _overStartPage(
            LinuxUpdateDialog.check(
              current: const AppVersion('0.4.1', 25),
              check: () async => null,
              install: _neverInstalls,
            ),
          ),
        ),
        WidgetbookUseCase(
          name: 'Could not check',
          builder: (_) => _overStartPage(
            LinuxUpdateDialog.check(
              current: const AppVersion('0.4.1', 25),
              check: () async =>
                  throw Exception('The update server answered 503.'),
              install: _neverInstalls,
            ),
          ),
        ),
        WidgetbookUseCase(
          name: 'Available',
          builder: (_) => _overStartPage(
            LinuxUpdateDialog.offer(
              current: const AppVersion('0.4.1', 25),
              update: _sampleUpdate,
              install: _neverInstalls,
              onSkip: (_) async {},
            ),
          ),
        ),
      ],
    ),
    WidgetbookComponent(
      name: 'Remove from Applications (Linux)',
      useCases: [
        WidgetbookUseCase(
          name: 'Default',
          builder: (_) => _overStartPage(
            RemoveFromApplicationsDialog(
              appImagePath: homePath('AppImages/AppStudio-x86_64.AppImage'),
            ),
          ),
        ),
      ],
    ),
  ],
);
