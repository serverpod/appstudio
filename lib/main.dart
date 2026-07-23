import 'dart:async';

import 'package:flutter/material.dart';
import 'package:shadcn_ui/shadcn_ui.dart';
import 'package:webview_cef/webview_cef.dart';

import 'agent/agent_controller.dart';
import 'process/dev_session_cleanup.dart';
import 'process/serverpod_process.dart';
import 'session/project_session.dart';
import 'terminal/studio_terminal.dart';
import 'theme/app_theme.dart';
import 'theme/theme_controller.dart';
import 'toolchain/toolchain.dart';
import 'platform/macos_app_menu.dart';
import 'ui/studio_shell.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  await cleanupOrphanedDevSession();

  final themeController = ThemeController();
  await themeController.load();

  final toolchain = await Toolchain.resolve();
  final session = ProjectSession();
  await session.loadRecents();
  final terminal = StudioTerminal();
  final process = ServerpodProcessController(
    toolchain: toolchain,
    session: session,
    terminal: terminal,
  );
  final agent = AgentController(
    toolchain: toolchain,
    session: session,
  );

  runApp(
    AppStudioApp(
      themeController: themeController,
      toolchain: toolchain,
      session: session,
      terminal: terminal,
      process: process,
      agent: agent,
    ),
  );
}

class AppStudioApp extends StatefulWidget {
  const AppStudioApp({
    super.key,
    required this.themeController,
    required this.toolchain,
    required this.session,
    required this.terminal,
    required this.process,
    required this.agent,
  });

  final ThemeController themeController;
  final Toolchain toolchain;
  final ProjectSession session;
  final StudioTerminal terminal;
  final ServerpodProcessController process;
  final AgentController agent;

  @override
  State<AppStudioApp> createState() => _AppStudioAppState();
}

class _AppStudioAppState extends State<AppStudioApp> {
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
    );
    unawaited(_macMenu!.install());
  }

  void _showNewProjectDialog() {
    if (!mounted) return;
    showShadDialog<void>(
      context: context,
      builder: (context) => ShadDialog.alert(
        title: const Text('New Project'),
        description: const Text(
          'Creating a new Serverpod project from App Studio is not available yet.',
        ),
        actions: [
          ShadButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('OK'),
          ),
        ],
      ),
    );
  }

  @override
  void dispose() {
    _macMenu?.dispose();
    try {
      WebviewManager().quit();
    } catch (_) {}
    unawaited(widget.process.stop());
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
      listenable: widget.themeController,
      builder: (context, _) {
        return ShadApp(
          title: 'App Studio',
          debugShowCheckedModeBanner: false,
          theme: buildLightTheme(),
          darkTheme: buildDarkTheme(),
          themeMode: widget.themeController.mode,
          home: StudioShell(
            toolchain: widget.toolchain,
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
