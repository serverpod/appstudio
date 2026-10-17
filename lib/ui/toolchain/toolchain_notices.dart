import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:shad/shad.dart';

import '../../toolchain/tool_status.dart';
import '../../util/open_url.dart';
import '../../util/pretty_path.dart';
import '../../util/quit_app.dart';
import '../../widgets/command_block.dart';
import '../../widgets/error_banner.dart';
import 'tools_view.dart';
import '../../widgets/app_dialog.dart';
import '../../widgets/dialog_body.dart';

/// Serverpod's quick start — the route for a Flutter App Studio cannot use.
final kQuickStartUrl = Uri.parse('https://docs.serverpod.dev/quickstart');

/// Asks, once, on a first launch without a standard Flutter: App Studio does
/// not work with a Flutter managed by Puro or FVM yet.
///
/// Completes on Continue; Quit exits the process.
Future<void> showFlutterInstallNotice(BuildContext context) async {
  await showAppDialog<void>(
    context: context,
    barrierDismissible: false,
    barrierBlurSigma: 0,
    builder: (context) => const FlutterInstallNotice(),
  );
}

class FlutterInstallNotice extends StatefulWidget {
  const FlutterInstallNotice({super.key});

  @override
  State<FlutterInstallNotice> createState() => _FlutterInstallNoticeState();
}

class _FlutterInstallNoticeState extends State<FlutterInstallNotice> {
  late final _openGuide = TapGestureRecognizer()
    ..onTap = () => openUrl(kQuickStartUrl);

  @override
  void dispose() {
    _openGuide.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = ShadTheme.of(context);
    final link = TextStyle(
      color: theme.colorScheme.primary,
      decoration: TextDecoration.underline,
      decorationColor: theme.colorScheme.primary,
    );

    return PopScope(
      canPop: false,
      child: ShadDialog.alert(
        title: const Text('Before you start'),
        description: Text.rich(
          TextSpan(
            children: [
              const TextSpan(
                text: 'App Studio currently only works with a standard '
                    'Flutter installation. If you are using Puro or FVM, you '
                    'are better off following Serverpod\'s ',
              ),
              TextSpan(
                text: 'Quick Start guide',
                style: link,
                recognizer: _openGuide,
                mouseCursor: SystemMouseCursors.click,
              ),
              const TextSpan(
                text: '. If you are not using Puro or FVM, you are good to go.',
              ),
            ],
          ),
        ),
        actions: [
          ShadButton.outline(
            onPressed: quitApp,
            child: const Text('Quit'),
          ),
          ShadButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Continue'),
          ),
        ],
        child: const DialogBody(),
      ),
    );
  }
}

/// Tells a user upgrading from a build that kept its own tools that this one
/// installs them the standard way, before it removes the old copies.
Future<void> showLegacyInstallNotice(BuildContext context) async {
  await showAppDialog<void>(
    context: context,
    barrierDismissible: false,
    barrierBlurSigma: 0,
    builder: (context) => const LegacyInstallNotice(),
  );
}

class LegacyInstallNotice extends StatelessWidget {
  const LegacyInstallNotice({super.key});

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      child: ShadDialog.alert(
        title: const Text('App Studio now installs Flutter the standard way'),
        description: const Text(
          'Earlier versions of App Studio kept their own copies of Flutter '
          'and Serverpod. From now on, App Studio installs them the standard '
          'way, so your terminal, editors and AI agents all use the same '
          'tools.\n\n'
          'App Studio will now remove its old copies and set up the tools '
          'again.',
        ),
        actions: [
          ShadButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Continue'),
          ),
        ],
        child: const DialogBody(),
      ),
    );
  }
}

/// The command that brings [candidate] into range. Uses the SDK's full path:
/// the user's `flutter` may well be a different copy from the one found.
String manualUpdateCommand(ToolCandidate candidate) {
  final root = candidate.root ?? '';
  final pretty = prettyPath(root);
  // A Windows SDK: `flutter.bat`, and PowerShell — the terminal Windows opens —
  // needs `&` to run a quoted path. The full path either way: `~` is not
  // something every Windows shell expands.
  if (root.contains(r'\')) {
    final bat = '$root\\bin\\flutter.bat';
    final flutter = bat.contains(' ') ? '& "$bat"' : bat;
    final channel = candidate.facts['channel'];
    return [
      if (channel != null && channel != 'stable') '$flutter channel stable',
      '$flutter upgrade',
    ].join('\n');
  }
  final flutter = pretty.contains(' ')
      ? '"$root/bin/flutter"'
      : '$pretty/bin/flutter';
  final channel = candidate.facts['channel'];
  return [
    if (channel != null && channel != 'stable') '$flutter channel stable',
    '$flutter upgrade',
  ].join('\n');
}

/// Explains a copy that App Studio did not install and so will not change.
String manualUpdateMessage(ToolStatus status) {
  final candidate = status.bestRejected;
  final where =
      candidate?.root == null ? '' : ' in ${prettyPath(candidate!.root!)}';
  final name = status.spec.displayName;
  final found = candidate?.detectedVersion;
  if (candidate?.fitness == ToolFitness.wrongVersion) {
    final channel = candidate!.facts['channel'];
    final what = channel != null && channel != 'stable'
        ? 'is on the $channel channel'
        : 'is $found';
    return '$name$where $what, and App Studio needs '
        '${status.spec.accepts} on the stable channel.';
  }
  return '$name$where cannot be used: ${candidate?.reason ?? 'unknown'}.';
}

/// Blocks on a copy the user has to update themselves, until they have.
///
/// Completes once nothing needs a manual update any more; quitting exits the
/// process.
Future<void> showManualUpdateDialog(
  BuildContext context, {
  required ToolsView toolchains,
}) async {
  await showAppDialog<void>(
    context: context,
    barrierDismissible: false,
    barrierBlurSigma: 0,
    builder: (context) => ManualUpdateDialog(toolchains: toolchains),
  );
}

class ManualUpdateDialog extends StatefulWidget {
  const ManualUpdateDialog({super.key, required this.toolchains});

  final ToolsView toolchains;

  @override
  State<ManualUpdateDialog> createState() => _ManualUpdateDialogState();
}

class _ManualUpdateDialogState extends State<ManualUpdateDialog> {
  bool _checking = false;
  bool _stillNeeded = false;

  Future<void> _checkAgain() async {
    setState(() {
      _checking = true;
      _stillNeeded = false;
    });
    await widget.toolchains.refreshDeep();
    if (!mounted) return;
    if (widget.toolchains.inventory.needsManualUpdate.isEmpty) {
      Navigator.of(context).pop();
      return;
    }
    setState(() {
      _checking = false;
      _stillNeeded = true;
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = ShadTheme.of(context);
    final pending = widget.toolchains.inventory.needsManualUpdate;

    return PopScope(
      canPop: false,
      child: ShadDialog.alert(
        title: Text(
          pending.length == 1
              ? 'Update ${pending.single.spec.displayName}'
              : 'Update your tools',
        ),
        description: Text(
          'Run this in '
          '${defaultTargetPlatform == TargetPlatform.windows ? 'PowerShell' : 'Terminal'}'
          ', then check again.',
        ),
        actions: [
          ShadButton.outline(
            onPressed: quitApp,
            child: const Text('Quit'),
          ),
          ShadButton(
            enabled: !_checking,
            onPressed: _checking ? null : () => unawaited(_checkAgain()),
            leading: _checking
                ? const SizedBox.square(
                    dimension: 14,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : null,
            child: const Text('Check again'),
          ),
        ],
        child: DialogBody(
          child: SizedBox(
            width: double.infinity,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              mainAxisSize: MainAxisSize.min,
              children: [
                if (_stillNeeded) ...[
                  const ErrorBanner(
                    message: 'Still out of date. Check that the command '
                        'finished without errors.',
                  ),
                  const ShadGap(3),
                ],
                for (final status in pending) ...[
                  Text(
                    manualUpdateMessage(status),
                    style: theme.textTheme.muted,
                  ),
                  const ShadGap(2),
                  if (status.bestRejected case final candidate?
                      when candidate.fitness == ToolFitness.wrongVersion)
                    CommandBlock(command: manualUpdateCommand(candidate)),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}
