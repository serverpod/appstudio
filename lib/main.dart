import 'dart:async';
import 'dart:ui' show AppExitResponse;

import 'package:flutter/material.dart';
import 'package:shad/shad.dart';

import 'agent/agent_controller.dart';
import 'analytics/app_analytics.dart';
import 'platform/compact_window.dart';
import 'preview/compact_dialog_yield.dart';
import 'preview/preview_mode_controller.dart';
import 'process/dev_session_cleanup.dart';
import 'process/serverpod_process.dart';
import 'session/external_editors.dart';
import 'session/project_session.dart';
import 'theme/app_theme.dart';
import 'theme/theme_controller.dart';
import 'toolchain/toolchain_controller.dart';
import 'update/session_teardown.dart';
import 'update/update_controller.dart';
import 'platform/macos_app_menu.dart';
import 'ui/new_project_dialog.dart';
import 'ui/project_started_dialog.dart';
import 'ui/project_startup_dialog.dart';
import 'ui/uninstall/uninstall_confirm_dialog.dart';
import 'ui/uninstall/uninstalled_screen.dart';
import 'uninstall/uninstaller.dart';
import 'ui/toolchain/toolchain_setup_screen.dart';
import 'ui/studio_shell.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  await cleanupOrphanedDevSession();

  final themeController = ThemeController();
  await themeController.load();

  final toolchains = await ToolchainController.create();
  final session = ProjectSession();
  await session.loadRecents();
  final process = ServerpodProcessController(
    toolchains: toolchains,
    session: session,
  );
  final agent = AgentController(
    toolchains: toolchains,
    session: session,
    process: process,
  );
  final editors = ExternalEditorsController(session: session, process: process);
  final previewMode = PreviewModeController(window: CompactWindowChannel());

  // Never blocks launch: create() swallows its own failures and reports the
  // updater as unavailable.
  final updates = await UpdateController.create(
    process: process,
    agent: agent,
  );

  // Installed before the first event so nothing fires into the no-op default.
  // Debug builds send nothing unless APPSTUDIO_ANALYTICS=1 is set; see
  // AppAnalytics.create.
  installAppAnalytics(
    AppAnalytics.create(
      appVersion: updates.state.currentVersion,
      appBuild: updates.state.currentBuild,
    ),
  );
  appAnalytics.appOpened(
    toolchainSetupRequired: toolchains.needsSetup,
    toolSources: {
      for (final tool in toolchains.inventory.tools.values)
        tool.id.manifestId: tool.resolved?.source.name ?? 'missing',
    },
    recentProjectCount: session.recents.length,
  );

  runApp(
    AppStudioApp(
      themeController: themeController,
      toolchains: toolchains,
      session: session,
        process: process,
      agent: agent,
      editors: editors,
      updates: updates,
      previewMode: previewMode,
    ),
  );
}

class AppStudioApp extends StatefulWidget {
  const AppStudioApp({
    super.key,
    required this.themeController,
    required this.toolchains,
    required this.session,
    required this.process,
    required this.agent,
    required this.editors,
    required this.updates,
    required this.previewMode,
  });

  final ThemeController themeController;
  final ToolchainController toolchains;
  final ProjectSession session;
  final ServerpodProcessController process;
  final AgentController agent;
  final ExternalEditorsController editors;
  final UpdateController updates;
  final PreviewModeController previewMode;

  @override
  State<AppStudioApp> createState() => _AppStudioAppState();
}

class _AppStudioAppState extends State<AppStudioApp> {
  /// The menu bar lives above [ShadApp], so dialogs it opens need the app's
  /// own navigator context.
  final _navigatorKey = GlobalKey<NavigatorState>();
  late final _compactDialogYield = CompactDialogYield(widget.previewMode);
  MacAppMenu? _macMenu;

  /// Non-null once the uninstall has run; the UI never comes back.
  UninstallResult? _uninstalled;
  bool _uninstalling = false;

  /// Lets the teardown run *before* macOS terminates us.
  ///
  /// This is the only place a quit can be awaited. `dispose()` is synchronous,
  /// and on ⌘Q the isolate is killed at the OS's convenience. `opencode serve`
  /// is an ordinary child process and survived every single quit, reparented
  /// to launchd — and the Serverpod runner is detached by design, so nothing
  /// at all takes it down with us. The reclaim in `main()` is the backstop;
  /// this is the fix.
  AppLifecycleListener? _lifecycle;
  bool _exiting = false;

  /// The project the startup notice last fired for.
  ///
  /// Tracked as a path rather than a bool: switching straight from one project
  /// to another restarts the server and recompiles just as much as opening the
  /// first one, but `hasProject` never changes across that.
  String? _noticedProjectPath;

  /// Last value the File menu was synced against.
  ///
  /// `ToolchainController` notifies on every download progress tick, and
  /// `_sync` tears down and rebuilds the Open Recent items each time — two of
  /// those overlapping would duplicate entries. Only the transition matters.
  bool? _menuCanOpenProjects;

  @override
  void initState() {
    super.initState();
    _macMenu = MacAppMenu(
      session: widget.session,
      process: widget.process,
      agent: widget.agent,
      themeController: widget.themeController,
      onNewProject: _showNewProjectScreen,
      onCheckForUpdates: () => unawaited(widget.updates.checkForUpdates()),
      onUninstall: _confirmUninstall,
      canCheckForUpdates: () => widget.updates.state.canCheck,
      updatesUnavailableReason: () => widget.updates.state.unavailableReason,
      onSetAutomaticUpdates: (enabled) =>
          unawaited(widget.updates.setAutomaticallyChecks(enabled)),
      automaticUpdatesEnabled: () => widget.updates.state.automaticallyChecks,
      canOpenProjects: () => !_needsToolchainSetup,
    );
    // The menu item starts disabled if the updater is not ready yet; re-sync
    // when it settles.
    widget.updates.addListener(_syncMenu);
    // File → Open and Open Recent follow the toolchain, so the menu has to
    // re-sync when the last install lands.
    _menuCanOpenProjects = !_needsToolchainSetup;
    widget.toolchains.addListener(_onToolchainsChanged);
    _noticedProjectPath = widget.session.projectPath;
    widget.session.addListener(_onSessionChanged);
    _lifecycle = AppLifecycleListener(onExitRequested: _onExitRequested);
    unawaited(_macMenu!.install());
    // Clear anything a crashed install left behind. Fire and forget, so it
    // never delays launch; ToolchainSetupScreen drives the install itself.
    unawaited(widget.toolchains.collectGarbage());
  }

  /// Always answers [AppExitResponse.exit] — refusing would make the app
  /// unquittable, which is a far worse bug than a stray child process. The
  /// timeout is shorter than the one `dispose()` uses because the user is
  /// watching a quit here, not a relaunch.
  Future<AppExitResponse> _onExitRequested() async {
    if (_exiting) return AppExitResponse.exit;
    _exiting = true;
    try {
      await teardownSession(
        process: widget.process,
        agent: widget.agent,
        timeout: const Duration(seconds: 6),
      );
    } catch (e) {
      debugPrint('exit teardown failed: $e');
    }
    return AppExitResponse.exit;
  }

  void _syncMenu() => _macMenu?.refresh();

  void _onToolchainsChanged() {
    final canOpen = !_needsToolchainSetup;
    if (canOpen == _menuCanOpenProjects) return;
    _menuCanOpenProjects = canOpen;
    // The same flip swaps the setup screen for the shell, or back.
    //
    // Deferred, unlike the other two callers: this notification arrives from a
    // listener that can be running mid-build, and popping a route from inside a
    // build is illegal.
    //
    // This is what closes `ToolchainSetupDialog` on a first run — the flip
    // lands while the install is still finishing up, so the dialog has not
    // popped itself yet. Its own self-close checks that its route is still
    // current for exactly that reason: a second pop here would take `home` with
    // it and leave an empty navigator.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _clearPushedRoutes();
    });
    _syncMenu();
  }

  /// Whether the first-run setup screen owns the window — see
  /// [ToolchainController.needsSetup].
  bool get _needsToolchainSetup => widget.toolchains.needsSetup;

  /// Opening a project auto-starts the server, so this is the moment the long
  /// first compile begins — say so before it looks like a hang.
  void _onSessionChanged() {
    final path = widget.session.projectPath;
    if (path == _noticedProjectPath) return;
    _noticedProjectPath = path;
    if (path != null) appAnalytics.projectOpened();
    // A compact window must not outlive the preview it was framing: closing or
    // switching projects goes back to the full window before anything else. A
    // no-op when not minimized.
    widget.previewMode.expand();
    // The session can notify mid-build (closing a project rebuilds the shell),
    // and pushing a route from inside a build is illegal.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final navigatorContext = _navigatorKey.currentContext;
      if (!mounted || navigatorContext == null) return;
      // The shell swaps the start page for the panes underneath whatever is
      // pushed over it — ⌘O and Open Recent stay live while the Create
      // Project screen is up, and a project opened that way would otherwise
      // load behind it.
      _clearPushedRoutes();
      if (path == null) return;
      unawaited(_showProjectNotices(path));
    });
  }

  /// The two project notices, in order and never stacked.
  ///
  /// "Starting your project" covers the compile; it closes itself the moment
  /// the project is up, so awaiting it here is also how we wait out a user who
  /// leaves it sitting there. Only then does the "has started" notice go up.
  /// Pushing that one on a timer instead would land it on top of the first.
  Future<void> _showProjectNotices(String path) async {
    final startupContext = _navigatorKey.currentContext;
    if (startupContext == null) return;
    await maybeShowProjectStartupNotice(
      startupContext,
      process: widget.process,
    );
    if (!mounted || widget.session.projectPath != path) return;

    await _awaitProjectReady(path);
    // The project can be closed, swapped or restarted across a compile that
    // takes minutes, and the notice must not arrive for a project that is no
    // longer open.
    if (!mounted || widget.session.projectPath != path) return;

    final navigatorContext = _navigatorKey.currentContext;
    if (navigatorContext == null || !navigatorContext.mounted) return;
    await maybeShowProjectStartedNotice(
      navigatorContext,
      editors: widget.editors,
    );
  }

  /// Completes when the project is running, or when it is no longer [path].
  Future<void> _awaitProjectReady(String path) {
    if (widget.process.projectIsReady) return Future.value();

    final done = Completer<void>();
    void check() {
      if (done.isCompleted) return;
      if (!widget.process.projectIsReady &&
          widget.session.projectPath == path) {
        return;
      }
      done.complete();
    }

    widget.process.addListener(check);
    widget.session.addListener(check);
    return done.future.whenComplete(() {
      widget.process.removeListener(check);
      widget.session.removeListener(check);
    });
  }

  /// Drops everything pushed over [ShadApp.home].
  ///
  /// `home` is the *first* route, so swapping it happens underneath anything
  /// pushed on top: the new screen is there, and invisible. That is how
  /// uninstalling with the Create Project screen open left the user filling in
  /// a form for an app that had just deleted itself.
  ///
  /// Called from the three transitions that replace the screen rather than
  /// from `build`, so it stays a consequence of the thing that happened and
  /// not a side effect of painting.
  ///
  /// `Navigator.pop` does not consult `PopScope`, which is what makes this
  /// work on the Create Project screen mid-run — a screen the *user* may not
  /// dismiss is still cleared by the app.
  void _clearPushedRoutes() =>
      _navigatorKey.currentState?.popUntil((route) => route.isFirst);

  /// Runs the full uninstall, then replaces the UI with a dead-end screen.
  ///
  /// Nothing is restored afterwards: the toolchain is gone, preferences are
  /// cleared and the session is stopped, so returning to the normal UI would
  /// only let the user act on things that no longer exist — and re-saving a
  /// preference would undo part of what they just asked for.
  Future<void> _confirmUninstall() async {
    final navigatorContext = _navigatorKey.currentContext;
    if (!mounted || navigatorContext == null || _uninstalled != null) return;

    final uninstaller = Uninstaller(
      toolchains: widget.toolchains,
      process: widget.process,
      agent: widget.agent,
    );
    final removable = await widget.toolchains.removableTools();
    if (!mounted || !navigatorContext.mounted) return;
    final choice = await showUninstallConfirmDialog(
      navigatorContext,
      removableTools: removable,
    );
    if (choice == null || !mounted) return;

    // Both screens this leads to replace `home`, which is below anything the
    // user still has open.
    _clearPushedRoutes();
    setState(() => _uninstalling = true);
    final result = await uninstaller.run(choice);

    if (!mounted) return;
    setState(() {
      _uninstalling = false;
      _uninstalled = result;
    });
  }

  void _showNewProjectScreen() {
    final navigatorContext = _navigatorKey.currentContext;
    if (!mounted || navigatorContext == null) return;
    unawaited(
      showNewProjectScreen(
        navigatorContext,
        toolchains: widget.toolchains,
        session: widget.session,
      ),
    );
  }

  @override
  void dispose() {
    _lifecycle?.dispose();
    widget.updates.removeListener(_syncMenu);
    widget.toolchains.removeListener(_onToolchainsChanged);
    widget.session.removeListener(_onSessionChanged);
    _macMenu?.dispose();
    // Same teardown Sparkle runs before it relaunches, so the two paths cannot
    // drift apart. Skipped when the exit hook already ran it — that one was
    // awaited, and this one cannot be.
    if (!_exiting) {
      unawaited(
        teardownSession(
          process: widget.process,
          agent: widget.agent,
          ),
      );
    }
    widget.updates.dispose();
    // `teardownSession` stops the agent; this releases the notifier. It used to
    // do both, which is why the stop could not be awaited.
    widget.agent.dispose();
    widget.process.dispose();
    widget.session.dispose();
    widget.themeController.dispose();
    widget.previewMode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([
        widget.themeController,
        widget.toolchains,
        widget.previewMode,
      ]),
      builder: (context, _) {
        return ShadApp(
          navigatorKey: _navigatorKey,
          // Any dialog pushed over the compact preview expands it first —
          // dialogs are sized for the full shell and their barrier blur has
          // nothing to blur on a transparent window.
          navigatorObservers: [_compactDialogYield],
          title: 'App Studio',
          debugShowCheckedModeBanner: false,
          theme: buildLightTheme(),
          darkTheme: buildDarkTheme(),
          themeMode: widget.themeController.mode,
          // ShadApp paints an opaque ColoredBox behind every route; in the
          // compact preview the native window is transparent and that box is
          // the one thing left that would hide the desktop behind the frame.
          backgroundColor: widget.previewMode.compactWindow
              ? Colors.transparent
              : null,
          home: switch (_uninstalled) {
            final result? => UninstalledScreen(result: result),
            // The teardown stops the server and the agent, which takes a
            // moment; the shell would otherwise keep rendering panes for a
            // session that is being dismantled underneath it.
            null when _uninstalling => const UninstallingScreen(),
            // Before the start page, not over it: there is nothing to create or
            // open a project with yet.
            null when _needsToolchainSetup => ToolchainSetupScreen(
              toolchains: widget.toolchains,
            ),
            null => StudioShell(
              toolchains: widget.toolchains,
              session: widget.session,
              process: widget.process,
              agent: widget.agent,
                    editors: widget.editors,
              themeController: widget.themeController,
              previewMode: widget.previewMode,
            ),
          },
        );
      },
    );
  }
}
