import 'dart:async';

import 'package:flutter/material.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

import 'agent/agent_controller.dart';
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
import 'ui/new_project_dialog.dart';
import 'ui/toolchain/manage_tools_dialog.dart';
import 'ui/toolchain/toolchain_setup_dialog.dart';
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

  // Never blocks launch: create() swallows its own failures and reports the
  // updater as unavailable.
  final updates = await UpdateController.create(process: process, agent: agent);

  runApp(
    AppStudioApp(
      themeController: themeController,
      toolchains: toolchains,
      session: session,
      terminal: terminal,
      process: process,
      agent: agent,
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
    required this.updates,
  });

  final ThemeController themeController;
  final ToolchainController toolchains;
  final ProjectSession session;
  final StudioTerminal terminal;
  final ServerpodProcessController process;
  final AgentController agent;
  final UpdateController updates;

  @override
  State<AppStudioApp> createState() => _AppStudioAppState();
}

class _AppStudioAppState extends State<AppStudioApp> {
  /// The menu bar lives above [ShadApp], so dialogs it opens need the app's
  /// own navigator context.
  final _navigatorKey = GlobalKey<NavigatorState>();
  MacAppMenu? _macMenu;

  @override
  void initState() {
    super.initState();
    _macMenu = MacAppMenu(
      session: widget.session,
      process: widget.process,
      agent: widget.agent,
      themeController: widget.themeController,
      onNewProject: _showNewProjectDialog,
      onManageTools: _showManageToolsDialog,
      onCheckForUpdates: () => unawaited(widget.updates.checkForUpdates()),
      canCheckForUpdates: () => widget.updates.state.canCheck,
      updatesUnavailableReason: () =>
          widget.updates.state.unavailableReason,
      onSetAutomaticUpdates: (enabled) =>
          unawaited(widget.updates.setAutomaticallyChecks(enabled)),
      automaticUpdatesEnabled: () => widget.updates.state.automaticallyChecks,
    );
    // The menu item starts disabled if the updater is not ready yet; re-sync
    // when it settles.
    widget.updates.addListener(_syncMenu);
    unawaited(_macMenu!.install());
    // Clear anything a crashed install left behind, then offer to fetch what
    // is missing. Both after the first frame, so neither delays launch.
    unawaited(widget.toolchains.collectGarbage());
    WidgetsBinding.instance.addPostFrameCallback((_) => _offerToolchainSetup());
  }

  void _syncMenu() => _macMenu?.refresh();

  Future<void> _offerToolchainSetup() async {
    final navigatorContext = _navigatorKey.currentContext;
    if (!mounted || navigatorContext == null) return;
    await maybeShowToolchainSetup(
      navigatorContext,
      toolchains: widget.toolchains,
    );
  }

  void _showManageToolsDialog() {
    final navigatorContext = _navigatorKey.currentContext;
    if (!mounted || navigatorContext == null) return;
    unawaited(
      showManageToolsDialog(navigatorContext, toolchains: widget.toolchains),
    );
  }

  void _showNewProjectDialog() {
    final navigatorContext = _navigatorKey.currentContext;
    if (!mounted || navigatorContext == null) return;
    unawaited(
      showNewProjectDialog(
        navigatorContext,
        toolchains: widget.toolchains,
        session: widget.session,
      ),
    );
  }

  @override
  void dispose() {
    widget.updates.removeListener(_syncMenu);
    _macMenu?.dispose();
    // Same teardown Sparkle runs before it relaunches, so the two paths cannot
    // drift apart.
    unawaited(
      teardownSession(process: widget.process, agent: widget.agent),
    );
    widget.updates.dispose();
    widget.process.dispose();
    widget.terminal.dispose();
    widget.session.dispose();
    widget.themeController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: widget.themeController,
      builder: (context, _) {
        return ShadApp(
          navigatorKey: _navigatorKey,
          title: 'App Studio',
          debugShowCheckedModeBanner: false,
          theme: buildLightTheme(),
          darkTheme: buildDarkTheme(),
          themeMode: widget.themeController.mode,
          home: StudioShell(
            toolchains: widget.toolchains,
            session: widget.session,
            terminal: widget.terminal,
            process: widget.process,
            agent: widget.agent,
            themeController: widget.themeController,
          ),
        );
      },
    );
  }
}
