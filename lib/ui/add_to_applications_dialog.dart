import 'package:flutter/material.dart';
import 'package:shad/shad.dart';

import '../platform/linux/app_version.dart';
import '../theme/app_theme.dart';
import '../util/pretty_path.dart';
import '../widgets/dialog_body.dart';
import '../widgets/error_banner.dart';

/// How the user answered [AddToApplicationsDialog].
enum AddToApplicationsAnswer {
  /// App Studio is in the app menu now.
  added,

  /// Ask again on the next start.
  notNow,

  /// Never ask again on start. Help → Add to Applications still offers it.
  never,
}

/// Offers to add the running AppImage to the app menu (Linux only).
///
/// Runs [onAdd] itself and stays open on failure with the error, so a failed
/// step is said where the user asked for it. Writing the "don't ask again"
/// preference is the caller's job, which keeps this widget free of `dart:io`.
class AddToApplicationsDialog extends StatefulWidget {
  const AddToApplicationsDialog({
    super.key,
    required this.onAdd,
    this.currentFolder,
    this.keepsOriginal = false,
    this.replacedFile,
    this.offerDontAskAgain = true,
  });

  /// Adds App Studio to the app menu; throws with a message on failure.
  final Future<void> Function() onAdd;

  /// The folder the AppImage is in now, named in the text because Add moves
  /// it. Null when it is already in `~/AppImages`.
  final String? currentFolder;

  /// Add can only copy the file out of [currentFolder] (a folder App Studio
  /// cannot take it out of), so the original stays and the text says so.
  final bool keepsOriginal;

  /// Another file at the path Add moves this one to, left there by an
  /// earlier Add. It may be a newer build, so the question says Add replaces
  /// it. Null when there is none.
  final String? replacedFile;

  /// False from the Help menu: the user asked, so there is nothing to stop
  /// asking about, and the way out is Cancel rather than Not now.
  final bool offerDontAskAgain;

  @override
  State<AddToApplicationsDialog> createState() =>
      _AddToApplicationsDialogState();
}

class _AddToApplicationsDialogState extends State<AddToApplicationsDialog> {
  bool _dontAskAgain = false;
  bool _adding = false;
  String? _error;

  Future<void> _add() async {
    setState(() {
      _adding = true;
      _error = null;
    });
    try {
      await widget.onAdd();
      if (!mounted) return;
      Navigator.of(context).pop(AddToApplicationsAnswer.added);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _adding = false;
        _error = '$e';
      });
    }
  }

  void _close() => Navigator.of(context).pop(
    _dontAskAgain
        ? AddToApplicationsAnswer.never
        : AddToApplicationsAnswer.notNow,
  );

  @override
  Widget build(BuildContext context) {
    final folder = widget.currentFolder;
    final buttons = [
      ShadButton.outline(
        enabled: !_adding,
        onPressed: _adding ? null : _close,
        child: Text(widget.offerDontAskAgain ? 'Not now' : 'Cancel'),
      ),
      ShadButton(
        enabled: !_adding,
        onPressed: _adding ? null : _add,
        child: Text(_adding ? 'Adding…' : 'Add'),
      ),
    ];
    // The alert variant: no close X, since Not now is the way out.
    return ShadDialog.alert(
      title: const Text('Add App Studio to your applications?'),
      description: Text(
        [
          switch ((folder, widget.keepsOriginal)) {
            (null, _) => 'App Studio will appear in your app menu.',
            (final folder?, false) =>
              'App Studio will appear in your app menu, and the file moves '
                  'from ${prettyPath(folder)} to ~/AppImages.',
            (final folder?, true) =>
              'App Studio will appear in your app menu, with a copy of the '
                  'file in ~/AppImages. The one in ${prettyPath(folder)} '
                  'stays, since App Studio cannot move it from there.',
          },
          if (widget.replacedFile case final replaced?)
            'It replaces the App Studio already at ${prettyPath(replaced)}.',
        ].join(' '),
      ),
      actionsMainAxisSize: MainAxisSize.max,
      actionsMainAxisAlignment: widget.offerDontAskAgain
          ? MainAxisAlignment.spaceBetween
          : MainAxisAlignment.end,
      actions: [
        if (widget.offerDontAskAgain)
          // Flexible: with two buttons beside it the checkbox is the part
          // that can wrap.
          Flexible(
            child: ShadCheckbox(
              value: _dontAskAgain,
              enabled: !_adding,
              onChanged: (v) => setState(() => _dontAskAgain = v),
              label: Text("Don't ask again", style: kWeightMedium),
            ),
          ),
        Row(mainAxisSize: MainAxisSize.min, spacing: 8, children: buttons),
      ],
      child: DialogBody(
        child: switch (_error) {
          final error? => ErrorBanner(message: error),
          null => null,
        },
      ),
    );
  }
}

/// Confirms Help → Remove from Applications. Pops true to remove.
class RemoveFromApplicationsDialog extends StatelessWidget {
  const RemoveFromApplicationsDialog({super.key, required this.appImagePath});

  /// Where the AppImage stays, named so the user knows it is still there.
  final String appImagePath;

  @override
  Widget build(BuildContext context) {
    return ShadDialog.alert(
      title: const Text('Remove App Studio from your applications?'),
      description: Text(
        'App Studio leaves your app menu. The file stays at '
        '${prettyPath(appImagePath)}, and App Studio will not ask to add '
        'itself again.',
      ),
      actions: [
        ShadButton.outline(
          onPressed: () => Navigator.of(context).pop(false),
          child: const Text('Cancel'),
        ),
        ShadButton(
          onPressed: () => Navigator.of(context).pop(true),
          child: const Text('Remove'),
        ),
      ],
      child: const DialogBody(),
    );
  }
}

/// This copy is newer than the one App Studio added to the app menu: offers
/// to put it in that one's place. Runs [onReplace] itself and stays open on
/// failure, as [AddToApplicationsDialog] does. Pops true once replaced.
class ReplaceAddedCopyDialog extends StatefulWidget {
  const ReplaceAddedCopyDialog({
    super.key,
    required this.running,
    required this.added,
    required this.onReplace,
    this.currentFolder,
    this.keepsOriginal = false,
  });

  final AppVersion running;
  final AppVersion added;
  final Future<void> Function() onReplace;

  /// The folder this copy is in, which Replace moves it out of. Null when it
  /// is in `~/AppImages` already.
  final String? currentFolder;

  /// Replace can only copy this file out of [currentFolder], so it stays
  /// there and the text says so.
  final bool keepsOriginal;

  @override
  State<ReplaceAddedCopyDialog> createState() => _ReplaceAddedCopyDialogState();
}

class _ReplaceAddedCopyDialogState extends State<ReplaceAddedCopyDialog> {
  bool _replacing = false;
  String? _error;

  Future<void> _replace() async {
    setState(() {
      _replacing = true;
      _error = null;
    });
    try {
      await widget.onReplace();
      if (!mounted) return;
      Navigator.of(context).pop(true);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _replacing = false;
        _error = '$e';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final running = copyVersionLabel(widget.running, widget.added);
    final added = copyVersionLabel(widget.added, widget.running);
    final folder = widget.currentFolder;
    return ShadDialog.alert(
      title: Text('Replace App Studio $added with this version?'),
      description: Text(
        'This copy is App Studio $running, newer than the $added in your app '
        'menu. ${switch ((folder, widget.keepsOriginal)) {
          (null, _) => 'Replace puts it',
          (final folder?, false) => 'Replace moves it from '
              '${prettyPath(folder)} to ~/AppImages,',
          (final folder?, true) => 'Replace puts a copy of it from '
              '${prettyPath(folder)} into ~/AppImages,',
        }} in place of the older one.',
      ),
      actions: [
        ShadButton.outline(
          enabled: !_replacing,
          onPressed: _replacing ? null : () => Navigator.of(context).pop(false),
          child: const Text('Not now'),
        ),
        ShadButton(
          enabled: !_replacing,
          onPressed: _replacing ? null : _replace,
          child: Text(_replacing ? 'Replacing…' : 'Replace'),
        ),
      ],
      child: DialogBody(
        child: switch (_error) {
          final error? => ErrorBanner(message: error),
          null => null,
        },
      ),
    );
  }
}

/// This copy is older than the one App Studio added to the app menu: says
/// so, and offers to open that one instead. Pops true to open it. Replacing
/// the newer copy with this one is not offered: a downgrade is too easy to
/// click by accident.
class OlderCopyDialog extends StatelessWidget {
  const OlderCopyDialog({
    super.key,
    required this.running,
    required this.added,
  });

  final AppVersion running;
  final AppVersion added;

  @override
  Widget build(BuildContext context) {
    final running = copyVersionLabel(this.running, this.added);
    final added = copyVersionLabel(this.added, this.running);
    return ShadDialog.alert(
      title: const Text('A newer App Studio is in your app menu'),
      description: Text(
        'This copy is App Studio $running. Your app menu has $added.',
      ),
      actions: [
        ShadButton.outline(
          onPressed: () => Navigator.of(context).pop(false),
          child: const Text('Keep using this one'),
        ),
        ShadButton(
          onPressed: () => Navigator.of(context).pop(true),
          child: Text('Open $added'),
        ),
      ],
      child: const DialogBody(),
    );
  }
}
