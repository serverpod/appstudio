import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import '../platform/studio_notifications.dart';
import '../process/ide_integration.dart';
import '../process/project_ready_view.dart';
import '../util/home_dir.dart';
import 'external_editors_view.dart';
import 'project_session.dart';
import 'project_settings.dart';

/// How a project folder reaches an editor's macOS app.
///
/// Three doors, and each app takes exactly one. Two of them go through `open`,
/// which hands the request to LaunchServices and so routes it to the copy that
/// is *already running*; the third is the editor's own CLI, for an app whose
/// routing is better than what `open` can reach.
///
/// Picking the wrong door is not loud: `open` exits 0 for an app that launched
/// and dropped the path exactly as it does for one that opened it.
class _EditorApp {
  const _EditorApp(this.appName, {this.deepLink, this.cli});

  /// Bundle name under one of [_applicationDirectories]. Doubles as the
  /// installed check, which [deepLink] needs even more than the rest do:
  /// `open <scheme>://…` fails *silently* when nothing claims the scheme.
  final String appName;

  /// Builds the URL for an app that takes the project as a deep link. Null
  /// means it accepts the folder as a document — `open -a <bundle> <path>`.
  final Uri Function(String projectPath)? deepLink;

  /// The app's own command-line entry point, run in place of `open -a` when the
  /// bundle really carries it. Null for every app whose `open -a` behaviour is
  /// already right.
  final _EditorCli? cli;
}

/// An Electron editor's CLI, addressed inside the bundle rather than through
/// the `bin/` shell script it also ships.
///
/// The script is `#!/usr/bin/env bash`, so it needs a `PATH` we do not control,
/// and it carries a branch that will `curl … | bash` an agent binary onto the
/// machine if argument one happens to be `agent`. Both go away by spawning what
/// the script would have spawned: the bundle's Electron binary in node mode on
/// the CLI's entry point. `ELECTRON_RUN_AS_NODE=1` is passed through
/// `/usr/bin/env` so this stays a plain argument vector.
class _EditorCli {
  const _EditorCli({required this.executable, required this.script});

  /// Bundle-relative path to the Electron executable.
  final String executable;

  /// Bundle-relative path to the CLI's node entry point.
  final String script;
}

/// The editors we know how to hand a project to, in the order the buttons
/// appear and — because the started notice features the first — in preference
/// order.
///
/// OpenCode is last on purpose. It only appears at all when the user ticked it
/// — `ProjectSettings` records the picks, not the `builtIn` set that always
/// goes out as `--ide` — but App Studio already runs it in the Agent tab, so
/// an editor it does *not* have is the more useful next step to feature.
///
/// Claude and Codex earn a place here because each ships a real desktop app
/// that takes a project directory. A CLI does not qualify — there is no window
/// to open a folder in, and "open in …" has to mean something visible.
///
/// **Antigravity is the one absence.** `/Applications/Antigravity.app` is not
/// the IDE: it is a thin Electron shell around a Go language server, with no
/// `open-file` handler and no `CFBundleDocumentTypes`, so a folder handed to it
/// is dropped and `open` still exits 0. The editor is a separate bundle,
/// `Antigravity IDE.app`, and no route into it has been confirmed. It is left
/// out only because no build of it has been seen to open the folder it was
/// given.
const _editorApps = <IdeIntegration, _EditorApp>{
  IdeIntegration.cursor: _EditorApp('Cursor', cli: _cursorCli),
  IdeIntegration.vscode: _EditorApp('Visual Studio Code'),
  IdeIntegration.claude: _EditorApp('Claude', deepLink: _claudeDeepLink),
  IdeIntegration.codex: _EditorApp('Codex', deepLink: _codexDeepLink),
  IdeIntegration.opencode: _EditorApp('OpenCode', deepLink: _openCodeDeepLink),
};

/// Cursor's CLI, which is the only route that reaches its **Agents Window**.
///
/// `open -a Cursor <folder>` is not wrong so much as blind: it always opens a
/// classic editor window on the folder and leaves the Agents Window sitting on
/// whatever project it already had. For a user who works in that window,
/// "Open in Cursor" appeared to point at the wrong directory.
///
/// Cursor routes on how the request arrived, and the branch that hands a folder
/// to the Agents Window is gated on the *CLI* context — `VSCODE_CLI=1`, which
/// only `cli.js` sets. `open -a` arrives as a dock open instead, and Cursor's
/// dock branch handles a `.code-workspace` file and nothing else, so a plain
/// folder can never reach the window from there. Through the CLI it adapts by
/// itself: Agents Window last active gets a new agent scoped to the folder, a
/// classic window last active gets a classic window, and a project already open
/// is focused rather than duplicated.
///
/// **A deep link cannot do this**, which is worth writing down because it is the
/// obvious thing to reach for. `cursor://file/<path>` exists and does open the
/// folder, but it arrives as a *protocol* open — excluded from the Agents Window
/// routing the same way the dock is — and it first raises Cursor's own
/// "An external application wants to open … it may represent an attempted attack
/// on your system" confirmation. A scary modal in front of a classic window is
/// strictly worse than the classic window on its own.
///
/// Verified against Cursor 3.15.6, spawned with launchd's bare `PATH` to match a
/// Finder launch: the running instance was reused every time and no second copy
/// of the editor appeared.
const _cursorCli = _EditorCli(
  executable: 'Contents/MacOS/Cursor',
  script: 'Contents/Resources/app/out/cli.js',
);

/// `claude://code/new?folder=…`, which lands the project in Claude Code.
///
/// Read out of the shipped router (Claude 1.26832.0): host `code`, path `/new`,
/// `folder` taken with `getAll` so it repeats, alongside `q`/`prompt`. That is
/// a *different* host from `claude://cowork/new`, which takes the same
/// parameters and lands in Cowork instead.
///
/// Preferred over handing the bundle the folder as a document: the `open-file`
/// handler dispatches to Cowork with the directory merely selected, where this
/// opens the project in the surface the `--ide claude` config was written for.
///
/// No `q` is sent. It would prefill *and* start a task, and the button only
/// promises to open the project.
Uri _claudeDeepLink(String projectPath) =>
    Uri.parse('claude://code/new?folder=${Uri.encodeComponent(projectPath)}');

/// `opencode://open-project?directory=…`, the scheme the desktop app's own
/// `parseDeepLink` reads. It ignores a folder passed as a document — there is
/// no `open-file` handler in the shipped main process.
///
/// A cold start is fine: unhandled links queue until the window is up.
Uri _openCodeDeepLink(String projectPath) => Uri.parse(
  'opencode://open-project?directory=${Uri.encodeComponent(projectPath)}',
);

/// `codex://threads/new?path=…`, which OpenAI documents as taking an absolute
/// local directory. The `codex app <path>` CLI is not a substitute — its folder
/// behaviour is undocumented on macOS.
Uri _codexDeepLink(String projectPath) =>
    Uri.parse('codex://threads/new?path=${Uri.encodeComponent(projectPath)}');

/// Resolves the open project's configured editors against what is installed on
/// this Mac, and hands the project to one on request.
///
/// Rebinds on a project *path* change rather than on `hasProject`, like every
/// other controller that follows the session: switching straight from one
/// project to another changes the answer, and the boolean never moves.
class ExternalEditorsController extends ChangeNotifier
    implements ExternalEditorsView {
  ExternalEditorsController({
    required this.session,
    required this.process,
    Future<Set<IdeIntegration>> Function(String projectPath)? readEditors,
    String? Function(String appName)? findApp,
    bool Function(String path)? fileExists,
    Future<bool> Function(List<String> command)? launch,
  }) : _readEditors = readEditors ?? _defaultReadEditors,
       _findApp = findApp ?? _defaultFindApp,
       _fileExists = fileExists ?? _defaultFileExists,
       _launch = launch ?? _defaultLaunch {
    session.addListener(_onSessionChanged);
    process.addListener(_onProcessChanged);
    _canOpen = process.projectIsReady;
    _onSessionChanged();
  }

  final ProjectSession session;
  final ProjectReadyView process;

  final Future<Set<IdeIntegration>> Function(String projectPath) _readEditors;
  final String? Function(String appName) _findApp;
  final bool Function(String path) _fileExists;
  final Future<bool> Function(List<String> command) _launch;

  List<ExternalEditor> _editors = const [];

  /// What to run per [ExternalEditor.id], resolved when the project was bound.
  /// Kept here rather than on the value type so the view stays free of anything
  /// macOS-shaped.
  Map<String, _ResolvedApp> _resolved = const {};

  String? _boundProjectPath;

  bool _canOpen = false;

  /// Guards the async resolve against a project switch landing mid-flight — the
  /// second project's answer must not be overwritten by the first's.
  int _generation = 0;

  @override
  List<ExternalEditor> get editors => _editors;

  @override
  bool get canOpen => _canOpen;

  @override
  Future<void> open(ExternalEditor editor) async {
    final projectPath = _boundProjectPath;
    final resolved = _resolved[editor.id];
    if (projectPath == null || resolved == null) return;

    if (!await _launch(resolved.commandFor(projectPath))) {
      await StudioNotifications.show(
        title: 'App Studio',
        body: 'Could not open the project in ${editor.label}.',
        // The user just clicked a button in this window, so App Studio is
        // frontmost and the notification would otherwise be suppressed.
        force: true,
      );
    }
  }

  @override
  void dispose() {
    session.removeListener(_onSessionChanged);
    process.removeListener(_onProcessChanged);
    super.dispose();
  }

  void _onProcessChanged() {
    // The process notifies on every poll tick; only the edge is interesting.
    if (process.projectIsReady == _canOpen) return;
    _canOpen = process.projectIsReady;
    notifyListeners();
  }

  void _onSessionChanged() {
    final path = session.projectPath;
    if (path == _boundProjectPath) return;
    _boundProjectPath = path;
    unawaited(_resolve(path));
  }

  Future<void> _resolve(String? projectPath) async {
    final generation = ++_generation;

    final editors = <ExternalEditor>[];
    final resolved = <String, _ResolvedApp>{};
    if (projectPath != null) {
      final configured = await _readEditors(projectPath);
      for (final entry in _editorApps.entries) {
        if (!configured.contains(entry.key)) continue;
        final appPath = _findApp(entry.value.appName);
        if (appPath == null) continue;
        editors.add(
          ExternalEditor(id: entry.key.option, label: entry.key.label),
        );
        resolved[entry.key.option] = _ResolvedApp(
          app: entry.value,
          appPath: appPath,
          cli: _resolveCli(entry.value.cli, appPath),
        );
      }
    }

    if (generation != _generation) return;
    if (listEquals(editors, _editors)) return;
    _editors = List.unmodifiable(editors);
    _resolved = Map.unmodifiable(resolved);
    notifyListeners();
  }

  /// The CLI's absolute paths, or null to fall back to `open -a`.
  ///
  /// Both files ship inside the bundle — there is nothing for the user to
  /// install, and in particular this is *not* the `cursor` shim on `PATH` that
  /// the editor's own "install the command" action creates. The check is here
  /// so a future layout change downgrades the button to the old behaviour
  /// instead of breaking it.
  _ResolvedCli? _resolveCli(_EditorCli? cli, String appPath) {
    if (cli == null) return null;
    final executable = p.join(appPath, cli.executable);
    final script = p.join(appPath, cli.script);
    if (!_fileExists(executable) || !_fileExists(script)) return null;
    return _ResolvedCli(executable: executable, script: script);
  }
}

/// An editor found on this Mac, and how to hand it a folder.
class _ResolvedApp {
  const _ResolvedApp({required this.app, required this.appPath, this.cli});

  final _EditorApp app;
  final String appPath;

  /// Present only when the app declares a CLI *and* the bundle carries it.
  final _ResolvedCli? cli;

  /// `[executable, ...arguments]`.
  List<String> commandFor(String projectPath) {
    // A deep link goes through LaunchServices by scheme, so it does not take
    // the bundle path — but the bundle still had to be found, or the URL would
    // go nowhere and say nothing.
    if (app.deepLink case final link?) {
      return ['/usr/bin/open', link(projectPath).toString()];
    }
    if (cli case final cli?) {
      return [
        '/usr/bin/env',
        'ELECTRON_RUN_AS_NODE=1',
        cli.executable,
        cli.script,
        projectPath,
      ];
    }
    return ['/usr/bin/open', '-a', appPath, projectPath];
  }
}

/// A CLI confirmed to exist, at absolute paths.
class _ResolvedCli {
  const _ResolvedCli({required this.executable, required this.script});

  final String executable;
  final String script;
}

Future<Set<IdeIntegration>> _defaultReadEditors(String projectPath) async =>
    (await ProjectSettings.load(projectPath)).editors;

/// Where a macOS app can be installed without the user having done anything
/// unusual. `/Applications` first, so a system-wide install wins over a stale
/// per-user copy.
List<String> _applicationDirectories() => [
  '/Applications',
  if (homeDirectory() case final home?) p.join(home, 'Applications'),
];

bool _defaultFileExists(String path) => File(path).existsSync();

String? _defaultFindApp(String appName) {
  for (final dir in _applicationDirectories()) {
    final path = p.join(dir, '$appName.app');
    if (Directory(path).existsSync()) return path;
  }
  return null;
}

/// Runs `[executable, ...arguments]` — an editor's own CLI, or `open` with
/// either `-a <bundle> <path>` or a deep-link URL.
///
/// The `open -a` form passes the bundle *path*, never the name: `open -a Code`
/// asks LaunchServices to resolve the name, which can land on a different copy
/// than the one we checked for, or on nothing at all. The CLI form is built onto
/// that same found path, so it cannot drift from it either.
///
/// The parent environment is inherited on purpose. Launched from Finder that is
/// launchd's, which is what the CLI route was measured against; `PATH` only has
/// to be good enough for `/usr/bin/env`, which is addressed absolutely anyway.
Future<bool> _defaultLaunch(List<String> command) async {
  try {
    final result = await Process.run(command.first, command.skip(1).toList());
    return result.exitCode == 0;
  } on ProcessException {
    return false;
  }
}
