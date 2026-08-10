import 'package:appstudio/process/ide_integration.dart';
import 'package:appstudio/process/project_ready_view.dart';
import 'package:appstudio/session/external_editors.dart';
import 'package:appstudio/session/project_session.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

/// A session with no project on disk — `openPath` validates against a real
/// Serverpod package, which these tests have no use for.
class _FakeSession extends ProjectSession {
  String? _path;

  @override
  String? get projectPath => _path;

  void setPath(String? path) {
    _path = path;
    notifyListeners();
  }
}

class _FakeProcess extends ChangeNotifier implements ProjectReadyView {
  _FakeProcess({this.projectIsReady = false});

  @override
  bool projectIsReady;

  void setReady(bool value) {
    projectIsReady = value;
    notifyListeners();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  ExternalEditorsController controller({
    Map<String, Set<IdeIntegration>> editorsByProject = const {},
    Set<String> installedApps = const {
      'Cursor',
      'Visual Studio Code',
      'Claude',
      'Codex',
      'OpenCode',
    },
    required _FakeSession session,
    ProjectReadyView? process,
    List<List<String>>? launches,
    bool launchSucceeds = true,
    bool cliIsPresent = true,
  }) {
    return ExternalEditorsController(
      session: session,
      process: process ?? _FakeProcess(projectIsReady: true),
      readEditors: (path) async => editorsByProject[path] ?? const {},
      findApp: (name) =>
          installedApps.contains(name) ? '/Applications/$name.app' : null,
      fileExists: (_) => cliIsPresent,
      launch: (command) async {
        launches?.add(command);
        return launchSucceeds;
      },
    );
  }

  test('offers only editors that are configured and installed', () async {
    final session = _FakeSession()..setPath('/p');
    final editors = controller(
      session: session,
      editorsByProject: {
        '/p': {IdeIntegration.cursor, IdeIntegration.vscode},
      },
      // VS Code is configured for the project but not installed on this Mac.
      installedApps: {'Cursor'},
    );
    addTearDown(editors.dispose);
    await pumpEventQueue();

    expect(editors.editors.map((e) => e.id), ['cursor']);
    expect(editors.editors.single.label, 'Cursor');
  });

  test('offers nothing for Antigravity, installed or not', () async {
    // `/Applications/Antigravity.app` is a shell around a language server, not
    // the IDE — it drops a folder handed to it and `open` still exits 0.
    final session = _FakeSession()..setPath('/p');
    final editors = controller(
      session: session,
      editorsByProject: {
        '/p': {IdeIntegration.antigravity},
      },
      installedApps: {'Antigravity', 'Antigravity IDE'},
    );
    addTearDown(editors.dispose);
    await pumpEventQueue();

    expect(editors.editors, isEmpty);
  });

  test('features the chosen editor ahead of the built-in agent', () async {
    // OpenCode is `builtIn`, so it is configured for every project. Ordered
    // first it would always be the editor the started notice names, burying
    // the one the user actually picked.
    final session = _FakeSession()..setPath('/p');
    final editors = controller(
      session: session,
      editorsByProject: {
        '/p': {
          IdeIntegration.opencode,
          IdeIntegration.vscode,
          IdeIntegration.cursor,
          IdeIntegration.claude,
          IdeIntegration.codex,
        },
      },
    );
    addTearDown(editors.dispose);
    await pumpEventQueue();

    expect(editors.editors.map((e) => e.id), [
      'cursor',
      'vscode',
      'claude',
      'codex',
      'opencode',
    ]);
  });

  test('rebinds when the project changes, and clears when it closes', () async {
    final session = _FakeSession()..setPath('/one');
    final editors = controller(
      session: session,
      editorsByProject: {
        '/one': {IdeIntegration.cursor},
        '/two': {IdeIntegration.vscode},
      },
    );
    addTearDown(editors.dispose);
    await pumpEventQueue();
    expect(editors.editors.map((e) => e.id), ['cursor']);

    session.setPath('/two');
    await pumpEventQueue();
    expect(editors.editors.map((e) => e.id), ['vscode']);

    session.setPath(null);
    await pumpEventQueue();
    expect(editors.editors, isEmpty);
  });

  test(
    'a project switch mid-resolve does not restore the old answer',
    () async {
      final session = _FakeSession()..setPath('/one');
      final editors = ExternalEditorsController(
        session: session,
        process: _FakeProcess(projectIsReady: true),
        readEditors: (path) async {
          // The first project resolves slowly; the second overtakes it.
          if (path == '/one') await Future<void>.delayed(Duration.zero);
          return path == '/one'
              ? {IdeIntegration.cursor}
              : {IdeIntegration.vscode};
        },
        findApp: (name) => '/Applications/$name.app',
        launch: (_) async => true,
      );
      addTearDown(editors.dispose);

      session.setPath('/two');
      await pumpEventQueue();

      expect(editors.editors.map((e) => e.id), ['vscode']);
    },
  );

  test('cannot open until the project is running', () async {
    final session = _FakeSession()..setPath('/p');
    final process = _FakeProcess();
    var notifications = 0;
    final editors = controller(
      session: session,
      process: process,
      editorsByProject: {
        '/p': {IdeIntegration.cursor},
      },
    );
    addTearDown(editors.dispose);
    await pumpEventQueue();
    editors.addListener(() => notifications++);

    // The button is there while it is still compiling — it just cannot fire.
    expect(editors.editors.map((e) => e.id), ['cursor']);
    expect(editors.canOpen, isFalse);

    process.setReady(true);
    expect(editors.canOpen, isTrue);
    expect(notifications, 1);

    // The process notifies on every poll tick; only the edge is worth a rebuild.
    process.notifyListeners();
    expect(notifications, 1);
  });

  test('hands the folder to a document-opening app as a document', () async {
    final session = _FakeSession()..setPath('/p');
    final launches = <List<String>>[];
    final editors = controller(
      session: session,
      editorsByProject: {
        '/p': {IdeIntegration.vscode},
      },
      launches: launches,
    );
    addTearDown(editors.dispose);
    await pumpEventQueue();

    await editors.open(editors.editors.single);
    // `open` hands the request to LaunchServices, which routes it to the copy
    // already running. And the bundle path, never the name: `open -a Code`
    // re-resolves and can land on a copy we never checked.
    expect(launches, [
      ['/usr/bin/open', '-a', '/Applications/Visual Studio Code.app', '/p'],
    ]);
  });

  test('hands the folder to Cursor through the CLI inside its bundle', () async {
    // `open -a` always opens a classic window and leaves the Agents Window on
    // the project it already had, which is the whole bug. Cursor only routes a
    // folder to that window when the request arrives as a CLI open, and only
    // `cli.js` marks it as one.
    final session = _FakeSession()..setPath('/p');
    final launches = <List<String>>[];
    final editors = controller(
      session: session,
      editorsByProject: {
        '/p': {IdeIntegration.cursor},
      },
      launches: launches,
    );
    addTearDown(editors.dispose);
    await pumpEventQueue();

    await editors.open(editors.editors.single);
    // Addressed inside the bundle, so this does not depend on the user having
    // run Cursor's "install the `cursor` command" action.
    expect(launches, [
      [
        '/usr/bin/env',
        'ELECTRON_RUN_AS_NODE=1',
        '/Applications/Cursor.app/Contents/MacOS/Cursor',
        '/Applications/Cursor.app/Contents/Resources/app/out/cli.js',
        '/p',
      ],
    ]);
  });

  test('falls back to opening the folder as a document with no CLI', () async {
    // A layout change inside a future Cursor must downgrade the button to the
    // behaviour it had before, not break it.
    final session = _FakeSession()..setPath('/p');
    final launches = <List<String>>[];
    final editors = controller(
      session: session,
      editorsByProject: {
        '/p': {IdeIntegration.cursor},
      },
      launches: launches,
      cliIsPresent: false,
    );
    addTearDown(editors.dispose);
    await pumpEventQueue();

    await editors.open(editors.editors.single);
    expect(launches, [
      ['/usr/bin/open', '-a', '/Applications/Cursor.app', '/p'],
    ]);
  });

  test('hands the folder to a deep-link app as a URL', () async {
    final session = _FakeSession()..setPath('/My Projects/app');
    final launches = <List<String>>[];
    final editors = controller(
      session: session,
      editorsByProject: {
        '/My Projects/app': {
          IdeIntegration.claude,
          IdeIntegration.opencode,
          IdeIntegration.codex,
        },
      },
      launches: launches,
    );
    addTearDown(editors.dispose);
    await pumpEventQueue();

    for (final editor in editors.editors) {
      await editors.open(editor);
    }

    // A URL and nothing else, with the path percent-encoded — a bare space
    // would truncate the query. Claude's host is `code`, not `cowork`: both
    // take `folder`, and `cowork` lands somewhere else entirely.
    expect(launches, [
      ['/usr/bin/open', 'claude://code/new?folder=%2FMy%20Projects%2Fapp'],
      ['/usr/bin/open', 'codex://threads/new?path=%2FMy%20Projects%2Fapp'],
      [
        '/usr/bin/open',
        'opencode://open-project?directory=%2FMy%20Projects%2Fapp',
      ],
    ]);
  });

  test('a deep-link editor still has to be installed', () async {
    // Unlike `open -a`, `open <scheme>://…` exits 0 when nothing claims the
    // scheme, so the bundle check is the only thing standing between the user
    // and a button that does nothing.
    final session = _FakeSession()..setPath('/p');
    final editors = controller(
      session: session,
      editorsByProject: {
        '/p': {IdeIntegration.opencode},
      },
      installedApps: const {},
    );
    addTearDown(editors.dispose);
    await pumpEventQueue();

    expect(editors.editors, isEmpty);
  });

  test('opening after the project closed launches nothing', () async {
    final session = _FakeSession()..setPath('/p');
    final launches = <List<String>>[];
    final editors = controller(
      session: session,
      editorsByProject: {
        '/p': {IdeIntegration.cursor},
      },
      launches: launches,
    );
    addTearDown(editors.dispose);
    await pumpEventQueue();
    final cursor = editors.editors.single;

    session.setPath(null);
    await pumpEventQueue();

    await editors.open(cursor);
    expect(launches, isEmpty);
  });
}
