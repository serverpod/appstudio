import 'package:appstudio/process/ide_integration.dart';
import 'package:appstudio/process/new_project_view.dart';
import 'package:appstudio/ui/new_project_dialog.dart';
import 'package:appstudio/ui/start_page.dart';
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

/// The Create Project screen in one state. With [createOnOpen] it presses
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
      name: 'Create Project',
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
  ],
);
