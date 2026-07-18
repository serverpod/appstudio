import 'package:flutter/material.dart';
import 'package:webview_cef/webview_cef.dart';

import 'process/serverpod_process.dart';
import 'session/project_session.dart';
import 'terminal/studio_terminal.dart';
import 'theme/app_theme.dart';
import 'theme/theme_controller.dart';
import 'toolchain/toolchain.dart';
import 'ui/studio_shell.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

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

  runApp(
    AppStudioApp(
      themeController: themeController,
      toolchain: toolchain,
      session: session,
      terminal: terminal,
      process: process,
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
  });

  final ThemeController themeController;
  final Toolchain toolchain;
  final ProjectSession session;
  final StudioTerminal terminal;
  final ServerpodProcessController process;

  @override
  State<AppStudioApp> createState() => _AppStudioAppState();
}

class _AppStudioAppState extends State<AppStudioApp> {
  @override
  void dispose() {
    try {
      WebviewManager().quit();
    } catch (_) {}
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
        return MaterialApp(
          title: 'App Studio',
          debugShowCheckedModeBanner: false,
          theme: AppTheme.light(),
          darkTheme: AppTheme.dark(),
          themeMode: widget.themeController.mode,
          home: Scaffold(
            body: StudioShell(
              toolchain: widget.toolchain,
              session: widget.session,
              terminal: widget.terminal,
              process: widget.process,
              themeController: widget.themeController,
            ),
          ),
        );
      },
    );
  }
}
