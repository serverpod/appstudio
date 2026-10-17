import 'package:appstudio/platform/host_platform.dart';
import 'package:appstudio/process/ide_integration.dart';
import 'package:appstudio/process/project_ready_view.dart';
import 'package:appstudio/session/external_editors.dart';
import 'package:appstudio/session/project_session.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/fake_windows_system.dart';

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
      // These pin the macOS routes, whatever machine runs them.
      host: HostPlatform.macos,
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
        host: HostPlatform.macos,
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

  group('on Windows', () {
    const local = r'C:\Users\alex\AppData\Local';
    const cursorExe = r'C:\Users\alex\AppData\Local\Programs\cursor\Cursor.exe';
    const cursorCli =
        r'C:\Users\alex\AppData\Local\Programs\cursor\resources\app\out\cli.js';
    const project = r'C:\Users\alex\My Projects\app';

    ExternalEditorsController windowsController({
      required Set<IdeIntegration> configured,
      Set<String> files = const {},
      Map<String, String> protocols = const {},
      FakeWindowsSystem? windows,
      List<List<String>>? cliRuns,
    }) {
      final system = windows ?? FakeWindowsSystem();
      system.protocols.addAll(protocols);
      final session = _FakeSession()..setPath(project);
      return ExternalEditorsController(
        session: session,
        process: _FakeProcess(projectIsReady: true),
        readEditors: (path) async => path == project ? configured : const {},
        // macOS lookups must never be what decides a Windows editor.
        findApp: (_) => fail('looked for a macOS bundle'),
        fileExists: files.contains,
        launch: (_) => fail('launched a macOS command'),
        host: HostPlatform.windows,
        windows: system,
        environment: const {
          'LOCALAPPDATA': local,
          'ProgramFiles': r'C:\Program Files',
        },
        runElectronCli: (exe, arguments) async {
          cliRuns?.add([exe, ...arguments]);
          return true;
        },
      );
    }

    test('hands the folder to Cursor through its CLI, as an argument', () async {
      final runs = <List<String>>[];
      final editors = windowsController(
        configured: {IdeIntegration.cursor},
        files: {cursorExe, cursorCli},
        cliRuns: runs,
      );
      addTearDown(editors.dispose);
      await pumpEventQueue();

      expect(editors.editors.map((e) => e.id), ['cursor']);
      await editors.open(editors.editors.single);
      // The folder is one argument to a real `.exe` — never a `.cmd` line
      // that cmd.exe would re-parse, spaces and all.
      expect(runs, [
        [cursorExe, cursorCli, project],
      ]);
    });

    test('finds a machine-wide VS Code under Program Files', () async {
      const code = r'C:\Program Files\Microsoft VS Code\Code.exe';
      const cli =
          r'C:\Program Files\Microsoft VS Code\resources\app\out\cli.js';
      final runs = <List<String>>[];
      final editors = windowsController(
        configured: {IdeIntegration.vscode},
        files: {code, cli},
        cliRuns: runs,
      );
      addTearDown(editors.dispose);
      await pumpEventQueue();

      await editors.open(editors.editors.single);
      expect(runs, [
        [code, cli, project],
      ]);
    });

    test('offers no CLI editor whose script is missing', () async {
      // An executable without `cli.js` is a layout we have not seen; there is
      // no `open -a` to fall back to, so the button is better absent.
      final editors = windowsController(
        configured: {IdeIntegration.cursor},
        files: {cursorExe},
      );
      addTearDown(editors.dispose);
      await pumpEventQueue();

      expect(editors.editors, isEmpty);
    });

    test('opens a deep link through the shell', () async {
      final windows = FakeWindowsSystem();
      final editors = windowsController(
        configured: {IdeIntegration.claude, IdeIntegration.opencode},
        protocols: {'claude': 'Claude', 'opencode': 'OpenCode'},
        windows: windows,
      );
      addTearDown(editors.dispose);
      await pumpEventQueue();

      for (final editor in editors.editors) {
        await editors.open(editor);
      }
      expect(windows.opened, [
        'claude://code/new?folder=${Uri.encodeComponent(project)}',
        'opencode://open-project?directory=${Uri.encodeComponent(project)}',
      ]);
    });

    test('offers no deep link Windows has nothing registered for', () async {
      // An unregistered scheme raises a "choose an app" dialog rather than
      // failing, so it must never get as far as a button.
      final windows = FakeWindowsSystem();
      final editors = windowsController(
        configured: {IdeIntegration.codex},
        windows: windows,
      );
      addTearDown(editors.dispose);
      await pumpEventQueue();

      expect(editors.editors, isEmpty);
      expect(windows.opened, isEmpty);
    });

    test('offers nothing for Antigravity', () async {
      final editors = windowsController(
        configured: {IdeIntegration.antigravity},
        protocols: {'antigravity': 'Antigravity'},
      );
      addTearDown(editors.dispose);
      await pumpEventQueue();

      expect(editors.editors, isEmpty);
    });
  });
}
