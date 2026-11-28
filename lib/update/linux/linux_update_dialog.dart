import 'package:flutter/material.dart';
import 'package:shad/shad.dart';

import '../../platform/linux/app_version.dart';
import '../../widgets/determinate_progress.dart';
import '../../widgets/dialog_body.dart';
import '../../widgets/error_banner.dart';
import 'appcast.dart';
import 'update_signals.dart';

/// Downloads [item], checks it, replaces the AppImage and quits. Reports
/// progress through [onProgress] and stops when [cancellation] asks. Returns
/// false when cancelled, and throws with a message the user can read.
typedef InstallUpdate =
    Future<bool> Function(
      AppcastItem item, {
      required void Function(int received, int total) onProgress,
      required UpdateCancellation cancellation,
    });

enum _Phase {
  checking,
  upToDate,
  checkFailed,
  available,
  downloading,
  installing,
  failed,

  /// The new version is in place, but did not start: nothing to retry.
  installedNotStarted,
}

/// App Studio's update dialog on Linux, where no Sparkle draws one: checks
/// (from Help), offers a newer build, downloads it with a progress bar and
/// installs it. Every step that touches the disk or the network is a
/// callback, which keeps this widget free of `dart:io`.
class LinuxUpdateDialog extends StatefulWidget {
  /// Help → Check for Updates: starts by checking.
  const LinuxUpdateDialog.check({
    super.key,
    required this.current,
    required Future<AppcastItem?> Function() this.check,
    required this.install,
    this.onSkip,
  }) : update = null;

  /// The automatic check found [update]: starts by offering it.
  const LinuxUpdateDialog.offer({
    super.key,
    required this.current,
    required AppcastItem this.update,
    required this.install,
    this.onSkip,
  }) : check = null;

  /// The running build.
  final AppVersion current;
  final Future<AppcastItem?> Function()? check;
  final AppcastItem? update;
  final InstallUpdate install;

  /// Skip This Version; the button only shows with it.
  final Future<void> Function(AppcastItem item)? onSkip;

  @override
  State<LinuxUpdateDialog> createState() => _LinuxUpdateDialogState();
}

class _LinuxUpdateDialogState extends State<LinuxUpdateDialog> {
  late _Phase _phase;
  AppcastItem? _update;
  String? _error;
  int _received = 0;
  int _total = 0;
  UpdateCancellation? _cancellation;

  @override
  void initState() {
    super.initState();
    _update = widget.update;
    _phase = _update == null ? _Phase.checking : _Phase.available;
    if (_phase == _Phase.checking) _check();
  }

  @override
  void dispose() {
    // Taken off by something else — a project opening clears the routes —
    // while downloading: stop, rather than quit the app later mid-work.
    _cancellation?.cancel();
    super.dispose();
  }

  Future<void> _check() async {
    try {
      final update = await widget.check!();
      if (!mounted) return;
      setState(() {
        _update = update;
        _phase = update == null ? _Phase.upToDate : _Phase.available;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = '$e';
        _phase = _Phase.checkFailed;
      });
    }
  }

  Future<void> _install() async {
    final update = _update!;
    final cancellation = UpdateCancellation();
    setState(() {
      _cancellation = cancellation;
      _received = 0;
      _total = update.length;
      _error = null;
      _phase = _Phase.downloading;
    });
    try {
      final installing = await widget.install(
        update,
        onProgress: (received, total) {
          if (!mounted) return;
          setState(() {
            _received = received;
            _total = total;
            // The last byte is in: what follows is the signature and the
            // replacement, which cannot be cancelled.
            if (received >= total) _phase = _Phase.installing;
          });
        },
        cancellation: cancellation,
      );
      if (!mounted) return;
      // Installing ends with the app quitting, so the dialog stays as it is
      // until then. A cancelled download goes back to the offer.
      if (!installing) setState(() => _phase = _Phase.available);
    } on UpdateInstalledException catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.message;
        _phase = _Phase.installedNotStarted;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = '$e';
        _phase = _Phase.failed;
      });
    }
  }

  Future<void> _skip() async {
    await widget.onSkip!(_update!);
    if (mounted) Navigator.of(context).pop();
  }

  void _close() => Navigator.of(context).pop();

  String get _newVersion => copyVersionLabel(_update!.version, widget.current);
  String get _currentVersion =>
      copyVersionLabel(widget.current, _update!.version);

  @override
  Widget build(BuildContext context) => switch (_phase) {
    _Phase.checking => ShadDialog.alert(
      title: const Text('Checking for updates…'),
      actions: [
        ShadButton.outline(onPressed: _close, child: const Text('Cancel')),
      ],
      child: const DialogBody(child: DeterminateProgress(fraction: null)),
    ),
    _Phase.upToDate => ShadDialog.alert(
      title: const Text("You're up to date"),
      description: Text(
        'App Studio ${widget.current.version} is the newest version.',
      ),
      actions: [ShadButton(onPressed: _close, child: const Text('OK'))],
      child: const DialogBody(),
    ),
    _Phase.checkFailed => ShadDialog.alert(
      title: const Text('Could not check for updates'),
      actions: [ShadButton(onPressed: _close, child: const Text('OK'))],
      child: DialogBody(child: ErrorBanner(message: _error ?? '')),
    ),
    _Phase.available => ShadDialog.alert(
      title: Text('App Studio $_newVersion is available'),
      description: Text(
        'You have $_currentVersion. Installing restarts App Studio, which '
        'stops the server if it is running.',
      ),
      actionsMainAxisSize: MainAxisSize.max,
      actionsMainAxisAlignment: widget.onSkip == null
          ? MainAxisAlignment.end
          : MainAxisAlignment.spaceBetween,
      actions: [
        if (widget.onSkip != null)
          // The part that gives way when the row is short of room, rather
          // than the dialog overflowing.
          Flexible(
            child: FittedBox(
              fit: BoxFit.scaleDown,
              alignment: Alignment.centerLeft,
              child: ShadButton.ghost(
                onPressed: _skip,
                child: const Text('Skip This Version'),
              ),
            ),
          ),
        Row(
          mainAxisSize: MainAxisSize.min,
          spacing: 8,
          children: [
            ShadButton.outline(onPressed: _close, child: const Text('Later')),
            ShadButton(
              onPressed: _install,
              child: const Text('Install and Restart'),
            ),
          ],
        ),
      ],
      child: const DialogBody(),
    ),
    _Phase.downloading || _Phase.installing => ShadDialog.alert(
      title: Text(
        _phase == _Phase.downloading
            ? 'Downloading App Studio $_newVersion'
            : 'Installing App Studio $_newVersion',
      ),
      actions: [
        // Dims rather than disappears once there is nothing left to cancel.
        ShadButton.outline(
          enabled: _phase == _Phase.downloading,
          onPressed: _phase == _Phase.downloading
              ? () => _cancellation?.cancel()
              : null,
          child: const Text('Cancel'),
        ),
      ],
      child: DialogBody(
        child: DeterminateProgress(
          fraction: _phase == _Phase.downloading && _total > 0
              ? _received / _total
              : null,
          caption: _phase == _Phase.downloading
              ? formatTransferCaption(received: _received, total: _total)
              : 'Checking the download and restarting…',
          reserveCaptionLine: true,
        ),
      ),
    ),
    _Phase.installedNotStarted => ShadDialog.alert(
      title: Text('App Studio $_newVersion is installed'),
      actions: [ShadButton(onPressed: _close, child: const Text('OK'))],
      child: DialogBody(child: ErrorBanner(message: _error ?? '')),
    ),
    _Phase.failed => ShadDialog.alert(
      title: const Text('Could not update App Studio'),
      actions: [
        ShadButton.outline(onPressed: _close, child: const Text('Close')),
        ShadButton(onPressed: _install, child: const Text('Try Again')),
      ],
      child: DialogBody(child: ErrorBanner(message: _error ?? '')),
    ),
  };
}
