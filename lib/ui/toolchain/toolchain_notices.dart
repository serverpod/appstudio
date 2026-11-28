import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:shad/shad.dart';

import '../../toolchain/tool_status.dart';
import '../../util/pretty_path.dart';
import '../../util/quit_app.dart';
import '../../widgets/command_block.dart';
import '../../widgets/error_banner.dart';
import 'tools_view.dart';
import '../../widgets/app_dialog.dart';
import '../../widgets/dialog_body.dart';

/// Raised when FVM or Puro is installed but no `flutter` on `PATH` reaches it
/// ([ToolsView.needsFlutterNotice]). Says how to add a shim, the way the
/// Serverpod CLI does, and waits.
///
/// Completes with true on Continue — App Studio installs its own Flutter
/// instead — and false once Check again finds a `flutter`. Quit exits.
Future<bool> showFlutterShimNotice(
  BuildContext context, {
  required ToolsView toolchains,
}) async {
  final chose = await showAppDialog<bool>(
    context: context,
    barrierDismissible: false,
    barrierBlurSigma: 0,
    builder: (context) => FlutterShimNotice(toolchains: toolchains),
  );
  return chose ?? false;
}

class FlutterShimNotice extends StatefulWidget {
  const FlutterShimNotice({
    super.key,
    required this.toolchains,
    this.windows,
  });

  final ToolsView toolchains;

  /// Which steps to show. Defaults to the platform App Studio runs on;
  /// Widgetbook passes it to show both.
  final bool? windows;

  @override
  State<FlutterShimNotice> createState() => _FlutterShimNoticeState();
}

class _FlutterShimNoticeState extends State<FlutterShimNotice> {
  bool _checking = false;
  bool _stillMissing = false;

  bool get _windows =>
      widget.windows ?? defaultTargetPlatform == TargetPlatform.windows;

  Future<void> _checkAgain() async {
    setState(() {
      _checking = true;
      _stillMissing = false;
    });
    await widget.toolchains.refreshDeep();
    if (!mounted) return;
    if (!widget.toolchains.needsFlutterNotice) {
      Navigator.of(context).pop(false);
      return;
    }
    setState(() {
      _checking = false;
      _stillMissing = true;
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = ShadTheme.of(context);
    final found = widget.toolchains.inventory.flutterWrappers;
    final wrappers = found.isEmpty ? FlutterWrapper.values : found;
    final names = wrappers.map((w) => w.displayName).join(' and ');
    final one = wrappers.length == 1;
    final terminal = _windows ? 'PowerShell' : 'Terminal';

    return PopScope(
      canPop: false,
      child: ShadDialog.alert(
        title: const Text('Add a flutter shim'),
        description: Text(
          'App Studio found $names, but no flutter command on your PATH. '
          'App Studio, the Serverpod CLI and your editors all run flutter, so '
          '$names ${one ? 'needs' : 'need'} a flutter that hands off to '
          '${one ? 'it' : 'them'}.',
        ),
        actions: [
          ShadButton.outline(
            onPressed: quitApp,
            child: const Text('Quit'),
          ),
          ShadButton.outline(
            enabled: !_checking,
            onPressed: _checking ? null : () => Navigator.of(context).pop(true),
            child: const Text('Continue'),
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
                if (_stillMissing) ...[
                  ErrorBanner(
                    message: 'Still no flutter on your PATH. Open a new '
                        '$terminal window and check that '
                        '${_windows ? 'where.exe' : 'which'} flutter finds the '
                        'shim.',
                  ),
                  const ShadGap(3),
                ],
                for (final wrapper in wrappers)
                  for (final step in shimSteps(wrapper, windows: _windows)) ...[
                    Text(step.text, style: theme.textTheme.muted),
                    const ShadGap(2),
                    if (step.command case final command?) ...[
                      CommandBlock(command: command),
                      const ShadGap(3),
                    ],
                  ],
                Text(
                  'Then check again. Or continue without a shim, and App '
                  'Studio installs its own copy of Flutter.',
                  style: theme.textTheme.muted,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// One step of putting a shim in place: what to do, and the command for it
/// when there is one to run.
typedef ShimStep = ({String text, String? command});

/// How to give [wrapper] a `flutter` on `PATH`, on Windows or macOS.
///
/// FVM's steps are the Serverpod CLI's own (`_fvmShimInstructions` in its
/// `serverpod_command_runner.dart`), so a user who already followed the CLI's
/// has nothing new to do, and one who follows these has satisfied both. Puro
/// installs its shim along with itself, so its step only puts it on `PATH`.
List<ShimStep> shimSteps(FlutterWrapper wrapper, {required bool windows}) {
  return switch (wrapper) {
    FlutterWrapper.fvm when windows => const [
        (
          text: 'FVM: create a flutter.bat that runs fvm flutter.',
          command: r'New-Item -ItemType Directory -Force "$env:USERPROFILE\.fvm_shim" | Out-Null'
              '\n'
              r'Set-Content "$env:USERPROFILE\.fvm_shim\flutter.bat" "@fvm flutter %*"',
        ),
        (
          text: r'Add %USERPROFILE%\.fvm_shim to the top of your user Path in '
              'Environment Variables. Then give FVM a global version, or the '
              'shim calls itself outside projects pinned with FVM:',
          command: 'fvm install stable\nfvm global stable',
        ),
      ],
    FlutterWrapper.fvm => const [
        (
          text: 'FVM: create a flutter that runs fvm flutter.',
          command: 'mkdir -p ~/.fvm_shim\n'
              r"""printf '#!/bin/sh\nexec fvm flutter "$@"\n' > ~/.fvm_shim/flutter"""
              '\n'
              'chmod +x ~/.fvm_shim/flutter',
        ),
        (
          text: "Put it first on your PATH, in ~/.zshrc or your shell's "
              'startup file:',
          command: r'export PATH="$HOME/.fvm_shim:$PATH"',
        ),
        (
          text: 'Then give FVM a global version, or the shim calls itself '
              'outside projects pinned with FVM:',
          command: 'fvm install stable\nfvm global stable',
        ),
      ],
    FlutterWrapper.puro when windows => const [
        (
          text: r'Puro: add %USERPROFILE%\.puro\bin to the top of your user '
              'Path in Environment Variables. Its flutter is there, and runs '
              'the environment you choose with puro use --global <env>.',
          command: null,
        ),
      ],
    FlutterWrapper.puro => const [
        (
          text: "Puro: put its bin folder first on your PATH, in ~/.zshrc or "
              "your shell's startup file. Its flutter is there, and runs the "
              'environment you choose with puro use --global <env>.',
          command: r'export PATH="$HOME/.puro/bin:$PATH"',
        ),
      ],
  };
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

/// The command that brings [candidate] into range, or null when there is no
/// one command to give. Uses the SDK's full path: the user's `flutter` may
/// well be a different copy from the one found.
///
/// An SDK a version manager keeps is updated through it — `flutter upgrade`
/// inside one is what FVM and Puro tell you not to do. Behind any other shim
/// (asdf, mise) there is no command App Studio can know.
String? manualUpdateCommand(ToolCandidate candidate) {
  final root = candidate.root ?? '';
  switch (flutterWrapperFor(root)) {
    case FlutterWrapper.fvm:
      return 'fvm install stable\nfvm global stable';
    case FlutterWrapper.puro:
      // ~/.puro/envs/<env>/flutter
      final segments = root.split(RegExp(r'[/\\]'));
      final envs = segments.lastIndexOf('envs');
      if (envs < 0 || envs + 1 >= segments.length) return null;
      return 'puro upgrade ${segments[envs + 1]}';
    case null:
      if (candidate.launcher != null) return null;
  }
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

/// What to run for a tool the user has to fix themselves, or null when there
/// is no one command: Flutter's own update for an old Flutter
/// ([manualUpdateCommand]), the distro's install command for Linux's missing
/// system packages.
String? manualCommandFor(ToolStatus status) {
  final candidate = status.bestRejected;
  if (candidate == null) return null;
  if (status.id == ToolId.systemPackages) {
    return candidate.facts['installCommand'];
  }
  if (candidate.fitness != ToolFitness.wrongVersion) return null;
  return manualUpdateCommand(candidate);
}

/// `a`, `a and b`, `a, b and c`.
String _andList(List<String> items) => items.length <= 1
    ? items.join()
    : '${items.sublist(0, items.length - 1).join(', ')} and ${items.last}';

/// Explains a copy that App Studio did not install and so will not change —
/// or, on Linux, the system packages it does not install at all.
String manualUpdateMessage(ToolStatus status) {
  if (status.id == ToolId.systemPackages) {
    final facts = status.bestRejected?.facts ?? const {};
    final missing = (facts['missing'] ?? '').split(' ')
      ..removeWhere((m) => m.isEmpty);
    final how = facts['installCommand'] == null
        ? ' Install ${missing.length == 1 ? 'it' : 'them'} with your '
              'distribution\'s package manager: '
              '${(facts['packages'] ?? '').split(' ').join(', ')}.'
        : '';
    return 'Flutter needs ${_andList(missing)}, and '
        '${missing.length == 1 ? 'it is' : 'they are'} not installed.$how';
  }
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
    final how = manualUpdateCommand(candidate) == null
        ? ' Update it with the tool that manages it.'
        : '';
    return '$name$where $what, and App Studio needs '
        '${status.spec.accepts} on the stable channel.$how';
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
          pending.every((s) => s.id == ToolId.systemPackages)
              ? 'Install system packages'
              : pending.length == 1
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
                  ErrorBanner(
                    message: pending.every(
                      (s) => s.id == ToolId.systemPackages,
                    )
                        ? 'Still missing. Check that the command finished '
                            'without errors.'
                        : 'Still out of date. Check that the command '
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
                  if (manualCommandFor(status) case final command?)
                    CommandBlock(command: command),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}
