/// An open project's window, assembled from the real toolbar, pane headers and
/// preview overlay — the context most dialogs and all the chrome appear in.
///
/// Two parts are stand-ins, because they are native: the server log is a plain
/// xterm with sample output rather than a live PTY, and the preview is a
/// placeholder where CEF would draw the app.
library;

import 'package:appstudio/preview/preview_device.dart';
import 'package:appstudio/preview/preview_hero_gradient.dart';
import 'package:appstudio/preview/preview_phase.dart';
import 'package:appstudio/preview/preview_status_overlay.dart';
import 'package:appstudio/preview/preview_theme.dart';
import 'package:appstudio/preview/registration_code_toast.dart';
import 'package:appstudio/process/full_restart_view.dart';
import 'package:appstudio/session/external_editors_view.dart';
import 'package:appstudio/theme/app_theme.dart';
import 'package:appstudio/ui/preview_header_bars.dart';
import 'package:appstudio/ui/studio_toolbar.dart';
import 'package:appstudio/ui/terminal_pane.dart';
import 'package:appstudio/ui/toolchain/tools_view.dart';
import 'package:flutter/material.dart';
import 'package:shad/shad.dart';
import 'package:xterm/xterm.dart';

import 'fakes/project.dart';
import 'fakes/tools.dart';

class StudioWindowMock extends StatelessWidget {
  const StudioWindowMock({
    super.key,
    this.phase = PreviewPhase.ready,
    this.errorMessage,
    this.tools,
    this.editors,
    this.process,
    this.registrationCode,
    this.viewMode = PreviewViewMode.phonePortrait,
  });

  final PreviewPhase phase;
  final String? errorMessage;
  final ToolsView? tools;
  final ExternalEditorsView? editors;
  final FullRestartView? process;
  final String? registrationCode;
  final PreviewViewMode viewMode;

  @override
  Widget build(BuildContext context) {
    final scheme = ShadTheme.of(context).colorScheme;
    return Column(
      children: [
        StudioToolbar(
          projectName: 'bookshelf',
          projectPath: homePath('Projects/bookshelf'),
          tools: tools ?? FakeToolsView(inventory: completeInventory),
          process: process ?? FakeFullRestart(),
          mcp: FakeHotRestart(),
          editors: editors ??
              FakeExternalEditors(
                editors: const [cursorEditor, claudeEditor],
                canOpen: phase == PreviewPhase.ready,
              ),
          onToggleLeftPanel: () {},
          onManageTools: () {},
        ),
        Expanded(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SizedBox(
                width: 460,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    TerminalPaneHeader(
                      tab: TerminalPaneTab.serverLogs,
                      onChanged: (_) {},
                    ),
                    Expanded(child: _SampleLog(failed: phase.isError)),
                  ],
                ),
              ),
              SizedBox(
                width: kDividerWidth,
                child: ColoredBox(color: scheme.border),
              ),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    PreviewHeaderBar(
                      previewBrightness: Brightness.light,
                      viewMode: viewMode,
                      minimized: false,
                      onPreviewThemeChanged: (_) {},
                      onViewModeChanged: (_) {},
                      onToggleMinimized: () {},
                    ),
                    Expanded(child: _PreviewArea(this)),
                  ],
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _PreviewArea extends StatelessWidget {
  const _PreviewArea(this.window);

  final StudioWindowMock window;

  @override
  Widget build(BuildContext context) {
    final phase = window.phase;
    return Stack(
      fit: StackFit.expand,
      children: [
        PreviewHeroGradient(
          animating: phase.showsLoadingOverlay,
          child: Center(
            child: phase == PreviewPhase.ready
                ? const _AppPlaceholder()
                : const SizedBox.shrink(),
          ),
        ),
        PreviewStatusOverlay(phase: phase, errorMessage: window.errorMessage),
        if (window.registrationCode case final code?)
          Positioned(
            top: 16,
            right: 16,
            child: RegistrationCodeToast(code: code, onDismiss: () {}),
          ),
      ],
    );
  }
}

/// Where CEF would draw the user's app.
class _AppPlaceholder extends StatelessWidget {
  const _AppPlaceholder();

  @override
  Widget build(BuildContext context) {
    final theme = ShadTheme.of(context);
    return Container(
      width: 300,
      height: 600,
      decoration: BoxDecoration(
        color: previewBackdropColor(Brightness.light),
        borderRadius: BorderRadius.circular(36),
        border: Border.all(color: Colors.black, width: 10),
      ),
      alignment: Alignment.center,
      child: Text(
        'The app renders here',
        style: theme.textTheme.muted.copyWith(color: Colors.black54),
      ),
    );
  }
}

/// A server log with what `serverpod start` prints on a good day — or, with
/// [failed], a compile error.
class _SampleLog extends StatefulWidget {
  const _SampleLog({required this.failed});

  final bool failed;

  @override
  State<_SampleLog> createState() => _SampleLogState();
}

class _SampleLogState extends State<_SampleLog> {
  final _terminal = Terminal(maxLines: 1000);

  static const _green = '\x1B[32m';
  static const _red = '\x1B[31m';
  static const _dim = '\x1B[2m';
  static const _reset = '\x1B[0m';

  @override
  void initState() {
    super.initState();
    final lines = [
      '${_dim}Serverpod 4.0.3$_reset',
      '$_green✓$_reset Generated code in 1.2s',
      if (widget.failed) ...[
        '$_red✗$_reset Compiling server',
        'lib/src/endpoints/book_endpoint.dart:14:5: Error: Undefined name '
            "'shelf'.",
      ] else ...[
        '$_green✓$_reset Compiled server in 8.4s',
        'Server listening on http://localhost:8080',
        'Flutter web server on http://localhost:9998',
        '$_green✓$_reset Browser refresh triggered.',
      ],
    ];
    _terminal.write(lines.join('\r\n'));
  }

  @override
  Widget build(BuildContext context) {
    final theme = ShadTheme.of(context);
    return TerminalView(
      _terminal,
      theme: TerminalPane.terminalTheme(theme),
      textStyle: const TerminalStyle(
        fontSize: kTerminalFontSize,
        fontFamily: kMacMonoFont,
      ),
      padding: const EdgeInsets.all(8),
      readOnly: true,
    );
  }
}
