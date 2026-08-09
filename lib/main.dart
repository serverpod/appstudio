import 'dart:async';
import 'dart:ui' show AppExitResponse;

import 'package:flutter/material.dart';
import 'package:shad/shad.dart';

import 'agent/agent_controller.dart';
import 'mcp/mcp_controller.dart';
import 'process/dev_session_cleanup.dart';
import 'process/serverpod_process.dart';
import 'session/project_session.dart';
import 'terminal/studio_terminal.dart';
import 'theme/app_theme.dart';
import 'theme/theme_controller.dart';
import 'toolchain/toolchain_controller.dart';
import 'update/session_teardown.dart';
import 'update/update_controller.dart';
import 'platform/macos_app_menu.dart';
import 'ui/landing_scaffold.dart';
import 'ui/new_project_dialog.dart';
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
  final terminal = StudioTerminal();
  final process = ServerpodProcessController(
    toolchains: toolchains,
    session: session,
    terminal: terminal,
  );
  final agent = AgentController(
    toolchains: toolchains,
    session: session,
    process: process,
  );
  final mcp = McpController(
    toolchains: toolchains,
    session: session,
    process: process,
  );

  // Never blocks launch: create() swallows its own failures and reports the
  // updater as unavailable.
  final updates = await UpdateController.create(
    process: process,
    agent: agent,
    mcp: mcp,
  );

  runApp(
    AppStudioApp(
      themeController: themeController,
      toolchains: toolchains,
      session: session,
      terminal: terminal,
      process: process,
      agent: agent,
      mcp: mcp,
      updates: updates,
    ),
  );
}

class AppStudioApp extends StatefulWidget {
  const AppStudioApp({
    super.key,
    required this.themeController,
    required this.toolchains,
    required this.session,
    required this.terminal,
    required this.process,
    required this.agent,
    required this.mcp,
    required this.updates,
  });

  final ThemeController themeController;
  final ToolchainController toolchains;
  final ProjectSession session;
  final StudioTerminal terminal;
  final ServerpodProcessController process;
  final AgentController agent;
  final McpController mcp;
  final UpdateController updates;

  @override
  State<AppStudioApp> createState() => _AppStudioAppState();
}

class _AppStudioAppState extends State<AppStudioApp> {
  /// The menu bar lives above [ShadApp], so dialogs it opens need the app's
  /// own navigator context.
  final _navigatorKey = GlobalKey<NavigatorState>();
  MacAppMenu? _macMenu;

  /// Non-null once the uninstall has run; the UI never comes back.
  UninstallResult? _uninstalled;
  bool _uninstalling = false;

  /// Lets the teardown run *before* macOS terminates us.
  ///
  /// This is the only place a quit can be awaited. `dispose()` is synchronous,
  /// and on ⌘Q the isolate is killed at the OS's convenience — measured: the
  /// server and the MCP bridge died with us, but `opencode serve` is an ordinary
  /// child process and survived every single quit, reparented to launchd. The
  /// pid-file reclaim in `main()` is the backstop; this is the fix.
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
        mcp: widget.mcp,
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

  /// Whether the first-run setup screen owns the window.
  ///
  /// Gated on `installable`, not on a complete toolchain: a required tool we
  /// have no artifact for cannot be fixed by the setup screen, so blocking on
  /// it would be a dead end. Those surface as the toolbar's destructive badge,
  /// pointing at Settings → Tools.
  bool get _needsToolchainSetup =>
      widget.toolchains.inventory.installable.isNotEmpty;

  /// Opening a project auto-starts the server, so this is the moment the long
  /// first compile begins — say so before it looks like a hang.
  void _onSessionChanged() {
    final path = widget.session.projectPath;
    if (path == _noticedProjectPath) return;
    _noticedProjectPath = path;
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
      unawaited(maybeShowProjectStartupNotice(navigatorContext));
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
      mcp: widget.mcp,
    );
    final choice = await showUninstallConfirmDialog(
      navigatorContext,
      measureBytes: uninstaller.measureSupportBytes,
    );
    if (choice == null || !mounted) return;

    // Both screens this leads to replace `home`, which is below anything the
    // user still has open.
    _clearPushedRoutes();
    setState(() => _uninstalling = true);
    final result = await uninstaller.run(clearPubCache: choice.clearPubCache);

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
          mcp: widget.mcp,
        ),
      );
    }
    widget.updates.dispose();
    widget.mcp.dispose();
    // `teardownSession` stops the agent; this releases the notifier. It used to
    // do both, which is why the stop could not be awaited.
    widget.agent.dispose();
    widget.process.dispose();
    widget.terminal.dispose();
    widget.session.dispose();
    widget.themeController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([widget.themeController, widget.toolchains]),
      builder: (context, _) {
        return ShadApp(
          navigatorKey: _navigatorKey,
          title: 'App Studio',
          debugShowCheckedModeBanner: false,
          theme: buildLightTheme(),
          darkTheme: buildDarkTheme(),
          themeMode: widget.themeController.mode,
          home: switch (_uninstalled) {
            final result? => UninstalledScreen(result: result),
            // The teardown stops the server and the agent, which takes a
            // moment; the shell would otherwise keep rendering panes for a
            // session that is being dismantled underneath it.
            null when _uninstalling => const _UninstallingScreen(),
            // Before the start page, not over it: there is nothing to create or
            // open a project with yet.
            null when _needsToolchainSetup => ToolchainSetupScreen(
              toolchains: widget.toolchains,
            ),
            null => StudioShell(
              toolchains: widget.toolchains,
              session: widget.session,
              terminal: widget.terminal,
              process: widget.process,
              agent: widget.agent,
              mcp: widget.mcp,
              themeController: widget.themeController,
            ),
          },
        );
      },
    );
  }
}

/// Shown while the uninstall runs. Brief, but the teardown can take a few
/// seconds and a frozen IDE would read as a hang.
///
/// On the same backdrop as [UninstalledScreen], which it hands straight over
/// to: two treatments across one uninstall would read as the window being
/// replaced twice.
class _UninstallingScreen extends StatelessWidget {
  const _UninstallingScreen();

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
